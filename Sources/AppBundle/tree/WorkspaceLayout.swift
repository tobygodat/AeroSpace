import AppKit
import Common

// Per-workspace layout mode (tiles, dwindle, scrolling, floating). See WorkspaceLayout in Common.
//
// The mode is a policy over the existing tree, not a new container algorithm:
// - it decides where a new tiling window is bound (`bindingDataForNewTilingWindow`),
// - it rebuilds the tree once when the mode changes (`applyLayout`),
// - it keeps the floating layout's invariant before every layout pass (`reconcileFloatingLayout`),
// - layoutRecursive stays untouched. Scrolling alone positions the root's children itself (`layoutScrolling`),
//   because its strip of columns is wider than the screen; each column is still laid out by layoutRecursive.

/// Set by the `workspace-layout` command, until reload-config. Keyed by name rather than stored on the Workspace
/// object, so an override on an empty workspace survives the workspace being garbage collected and recreated
@MainActor private var workspaceLayoutOverrides: [String: WorkspaceLayout] = [:]
private let floatedByLayoutKey = TreeNodeUserDataKey<Bool>(key: "workspaceLayout.floatedByLayout")
private let scrollOffsetKey = TreeNodeUserDataKey<CGFloat>(key: "workspaceLayout.scrollOffset")

extension Workspace {
    /// The effective layout: the last `workspace-layout` command wins, then the `[workspace-layout]` table, then
    /// `default-workspace-layout`
    @MainActor var layout: WorkspaceLayout {
        layoutOverride ?? config.workspaceLayouts[name] ?? config.defaultWorkspaceLayout
    }

    @MainActor var layoutOverride: WorkspaceLayout? {
        get { workspaceLayoutOverrides[name] }
        set { workspaceLayoutOverrides[name] = newValue }
    }

    /// Scrolling layout: how far the strip of columns is scrolled, in points from its left edge. `layoutScrolling`
    /// moves it only as much as needed to keep the focused column in view
    var scrollOffset: CGFloat {
        get { getUserData(key: scrollOffsetKey) ?? 0 }
        set { putUserData(key: scrollOffsetKey, data: newValue) }
    }

    /// Rebuilds the workspace tree for `layout`. Callers change `layoutOverride` or the config first.
    /// - tiles: flattens every tiling window into the root container (like `flatten-workspace-tree`)
    /// - dwindle: re-inserts the tiling windows in tree order with the dwindle policy, so the result is the spiral
    ///   the user would have gotten by opening them one by one
    /// - scrolling: one column per window, in tree order, at the configured column width, scrolled to the start
    /// - floating: floats every tiling window where it stands
    /// Leaving floating first tiles the windows the floating layout floated, in the order they floated.
    /// The most recent window stays the most recent one, so the next new window still splits the focused cell
    @MainActor
    func applyLayout() {
        let mru = mostRecentWindowRecursive
        if layout == .floating {
            floatTilingWindows()
        } else {
            let windows = rootTilingContainer.allLeafWindowsRecursive + floatingWindows.filter(\.floatedByLayout)
            for window in windows {
                window.unbindFromParent()
                window.floatedByLayout = false
            }
            // Only empty containers are left in the root. Dwindle counts the root's children, so they go now rather
            // than at the next normalization
            for container in rootTilingContainer.children {
                container.unbindFromParent()
            }
            if layout == .dwindle {
                rootTilingContainer.layout = .tiles
            }
            if layout == .scrolling {
                rootTilingContainer.layout = .tiles
                rootTilingContainer.setOrientationOnly(.h)
                scrollOffset = 0
            }
            for window in windows {
                let data = switch layout {
                    case .tiles: BindingData(parent: rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case .dwindle: dwindleBindingData()
                    case .scrolling: scrollingBindingData()
                    case .floating: die("handled above")
                }
                window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
            }
        }
        mru?.markAsMostRecentChild()
    }

    /// The floating layout is an invariant kept before every layout pass, not only when the layout changes: in a
    /// floating workspace no window tiles, and in any other workspace no window floats because of a layout.
    /// New windows, `move-node-to-workspace`, mouse drags and windows leaving a macOS native state all land in the
    /// tiling tree (or the floating container) first and are corrected here, so there is one place to get right
    @MainActor
    func reconcileFloatingLayout() {
        if layout == .floating {
            floatTilingWindows()
            return
        }
        for window in floatingWindows where window.floatedByLayout {
            window.unbindFromParent()
            window.floatedByLayout = false
            let data = bindingDataForNewTilingWindow()
            window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        }
    }

    /// Floats every tiling window without moving it, and marks it so that leaving the floating layout tiles it again.
    /// Windows that float for their own reasons (dialogs, `layout floating`) aren't touched and aren't marked
    @MainActor
    private func floatTilingWindows() {
        for window in rootTilingContainer.allLeafWindowsRecursive {
            window.lastFloatingSize = window.lastAppliedLayoutPhysicalRect?.size ?? window.lastFloatingSize
            window.bindAsFloatingWindow(to: self)
            window.floatedByLayout = true
        }
        for container in rootTilingContainer.children {
            container.unbindFromParent()
        }
    }

    /// Where a new tiling window goes on this workspace. The window, if it exists already, is unbound.
    /// - tiles: next to the most recent window in its container (AeroSpace's behavior)
    /// - dwindle: splits the most recent window's area along its longer side: the window is wrapped in a new
    ///   container oriented by `estimatedVirtualRect`, and the new window becomes its second child
    /// - scrolling: a new column right after the most recent window's column, `scrolling-column-width` wide
    /// - floating: like tiles. The window has to land somewhere before `reconcileFloatingLayout` floats and marks
    ///   it, because a window that is being registered has no `Window` object to mark yet
    @MainActor
    func bindingDataForNewTilingWindow() -> BindingData {
        switch layout {
            case .tiles, .floating: tilesBindingData()
            case .dwindle: dwindleBindingData()
            case .scrolling: scrollingBindingData()
        }
    }

    /// Scrolling: columns are the root's children (a window, or a vertical tiles container of windows), their
    /// width is their horizontal weight in points. The new window becomes a column right after the column of the
    /// most recent window, `config.scrollingColumnWidthPercent` of the workspace width wide
    @MainActor
    private func scrollingBindingData() -> BindingData {
        // MRU propagates up the tree, so the root's most recent child is the focused window's column
        let column = rootTilingContainer.mostRecentChild
        return BindingData(
            parent: rootTilingContainer,
            adaptiveWeight: defaultScrollingColumnWidth,
            index: column.map { $0.ownIndex.orDie() + 1 } ?? INDEX_BIND_LAST,
        )
    }

    /// Scrolling: `scrolling-column-width` percent of the workspace width, in whole points
    @MainActor
    var defaultScrollingColumnWidth: CGFloat {
        (CGFloat(config.scrollingColumnWidthPercent) / 100 * workspaceMonitor.visibleRectPaddedByOuterGaps.width).rounded()
    }

    @MainActor
    private func tilesBindingData() -> BindingData {
        let mruWindow = mostRecentWindowRecursive
        if let mruWindow, let tilingParent = mruWindow.parent as? TilingContainer {
            return BindingData(
                parent: tilingParent,
                adaptiveWeight: WEIGHT_AUTO,
                index: mruWindow.ownIndex.orDie() + 1,
            )
        } else {
            return BindingData(
                parent: rootTilingContainer,
                adaptiveWeight: WEIGHT_AUTO,
                index: INDEX_BIND_LAST,
            )
        }
    }

    /// Hyprland's dwindle: split the most recent window's area along its longer side. A lone window in a tiles
    /// container just gets a sibling and the container takes the split orientation. Otherwise the window is
    /// wrapped in a new container that keeps its slot and weight, and the new window joins it as an equal half.
    /// An accordion (from `layout accordion` or `default-root-container-layout`) is never used as the split
    /// container: the wrap keeps it as the user's tab bar around the split
    @MainActor
    private func dwindleBindingData() -> BindingData {
        guard let mru = rootTilingContainer.mostRecentWindowRecursive, let parent = mru.parent as? TilingContainer else {
            return BindingData(parent: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        let rect = mru.estimatedVirtualRect
        let orientation: Orientation = rect.width >= rect.height ? .h : .v
        if parent.children.count == 1 && parent.layout == .tiles {
            parent.setOrientationOnly(orientation)
            return BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        let index = mru.ownIndex.orDie()
        let weight = mru.getWeight(parent.orientation)
        mru.unbindFromParent()
        let container = TilingContainer(parent: parent, adaptiveWeight: weight, orientation, .tiles, index: index)
        mru.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: 0)
        return BindingData(parent: container, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}

extension Window {
    /// True while the window floats only because its workspace layout is floating. `layout floating` clears it:
    /// the window then floats by its own choice and stays floating when the workspace layout changes
    var floatedByLayout: Bool {
        get { getUserData(key: floatedByLayoutKey) ?? false }
        set {
            if newValue { putUserData(key: floatedByLayoutKey, data: true) } else { _ = cleanUserData(key: floatedByLayoutKey) }
        }
    }
}

extension TreeNode {
    /// The rect this node would get from layoutRecursive, computed from the tree alone (weights, orientations,
    /// accordion), ignoring gaps. Used where the last applied rect is stale or missing: hidden workspaces and
    /// rebuilds between layout passes. Gaps are ignored on purpose: Hyprland's dwindle picks the split axis from
    /// the node box before gaps too
    @MainActor
    var estimatedVirtualRect: Rect {
        if let workspace = self as? Workspace {
            return workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        }
        guard let parent else { die("\(self) is unbound, it has no rect") }
        let rect = parent.estimatedVirtualRect
        guard case .tilingContainer(let container) = parent.cases, container.layout == .tiles else { return rect }
        // layoutTiles doesn't split proportionally: it adds (available - sum of weights) / count to every child
        let orientation = container.orientation
        let weights = container.children.map { $0.getWeight(orientation) }
        let delta = (rect.getDimension(orientation) - weights.sumOfDouble { $0 }) / CGFloat(weights.count)
        let index = ownIndex.orDie()
        let offset = weights[..<index].sumOfDouble { $0 } + delta * CGFloat(index)
        let size = weights[index] + delta
        return switch orientation {
            case .h: Rect(topLeftX: rect.topLeftX + offset, topLeftY: rect.topLeftY, width: size, height: rect.height)
            case .v: Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY + offset, width: rect.width, height: size)
        }
    }
}

/// Runs after `config` was swapped by reload-config. Drops the runtime overrides and rebuilds the workspaces whose
/// effective layout changed, so a save from the Layouts pane takes effect immediately
@MainActor
func syncWorkspaceLayoutsAfterConfigReload(layoutsBeforeReload: [(workspace: Workspace, layout: WorkspaceLayout)]) {
    workspaceLayoutOverrides = [:]
    var rebuilt = false
    for (workspace, before) in layoutsBeforeReload where workspace.layout != before {
        workspace.applyLayout()
        rebuilt = true
    }
    // The lock-screen cache remembers trees; a rebuilt one must not come back on unlock
    if rebuilt { resetClosedWindowsCache() }
}
