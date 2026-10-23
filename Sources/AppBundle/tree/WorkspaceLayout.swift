import AppKit
import Common

// Per-workspace layout mode (tiles, dwindle, floating). See WorkspaceLayout in Common.
//
// The mode is a policy over the existing tree, not a new container algorithm:
// - it decides where a new tiling window is bound (`bindingDataForNewTilingWindow`),
// - it rebuilds the tree once when the mode changes (`applyLayout`),
// - layoutRecursive stays untouched.

private let layoutOverrideKey = TreeNodeUserDataKey<WorkspaceLayout>(key: "workspaceLayout.override")
private let windowsFloatedByLayoutKey = TreeNodeUserDataKey<[UInt32]>(key: "workspaceLayout.floatedWindowIds")

extension Workspace {
    /// The effective layout: the last `workspace-layout` command wins, then the `[workspace-layout]` table, then
    /// `default-workspace-layout`
    @MainActor var layout: WorkspaceLayout {
        layoutOverride ?? config.workspaceLayouts[name] ?? config.defaultWorkspaceLayout
    }

    /// Set by the `workspace-layout` command. reload-config clears it, so the config stays the source of truth
    var layoutOverride: WorkspaceLayout? {
        get { getUserData(key: layoutOverrideKey) }
        set {
            if let newValue { putUserData(key: layoutOverrideKey, data: newValue) } else { cleanUserData(key: layoutOverrideKey) }
        }
    }

    /// Ids of the windows the floating layout floated (on the switch and as they arrived), in tree order.
    /// Leaving the floating layout tiles exactly these. Windows that floated for their own reasons (dialogs,
    /// `layout floating`) keep floating
    var windowsFloatedByLayout: [UInt32] {
        get { getUserData(key: windowsFloatedByLayoutKey) ?? [] }
        set { putUserData(key: windowsFloatedByLayoutKey, data: newValue) }
    }

    /// Rebuilds the workspace tree for `target`. Callers decide whether `target` also becomes `layoutOverride`.
    /// - tiles: flattens every tiling window into the root container (like `flatten-workspace-tree`)
    /// - dwindle: re-inserts the tiling windows in tree order with the dwindle policy, so the result is the spiral
    ///   the user would have gotten by opening them one by one
    /// - floating: binds every tiling window to the floating container, keeping their frames, and records them
    /// Leaving floating first tiles the recorded windows (in recorded order) with the target policy.
    @MainActor
    func applyLayout(_ target: WorkspaceLayout) {
        let tiling = rootTilingContainer.allLeafWindowsRecursive
        if target == .floating {
            for window in tiling {
                window.lastFloatingSize = window.lastAppliedLayoutPhysicalRect?.size ?? window.lastFloatingSize
                window.bindAsFloatingWindow(to: self)
                if !windowsFloatedByLayout.contains(window.windowId) {
                    windowsFloatedByLayout.append(window.windowId)
                }
            }
            return
        }
        let returning = windowsFloatedByLayout.compactMap { id in floatingWindows.first { $0.windowId == id } }
        windowsFloatedByLayout = []
        let windows = tiling + returning
        for window in windows {
            window.unbindFromParent()
        }
        // Only empty containers are left in the root. Dwindle counts the root's children, so they go now rather
        // than at the next normalization
        for container in rootTilingContainer.children {
            container.unbindFromParent()
        }
        for window in windows {
            let data = target == .tiles
                ? BindingData(parent: rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                : dwindleBindingData()
            window.bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        }
    }

    /// Where a new tiling window goes on this workspace. `window` is already unbound, or nil for a window that is
    /// being registered (then only `windowId` is known).
    /// - tiles: next to the most recent window in its container (AeroSpace's behavior)
    /// - dwindle: splits the most recent window's area along its longer side: the window is wrapped in a new
    ///   container oriented by `estimatedVirtualRect`, and the new window becomes its second child
    /// - floating: the floating container; the window id is appended to `windowsFloatedByLayout`
    @MainActor
    func bindingDataForNewTilingWindow(windowId: UInt32, window: Window?) -> BindingData {
        switch layout {
            case .tiles: tilesBindingData()
            case .dwindle: dwindleBindingData()
            case .floating: floatingBindingData(windowId: windowId)
        }
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

    /// Hyprland's dwindle: split the most recent window's area along its longer side. A lone window in its
    /// container just gets a sibling and the container takes the split orientation. Otherwise the window is
    /// wrapped in a new container that keeps its slot and weight, and the new window joins it as an equal half
    @MainActor
    private func dwindleBindingData() -> BindingData {
        guard let mru = rootTilingContainer.mostRecentWindowRecursive, let parent = mru.parent as? TilingContainer else {
            return BindingData(parent: rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        let rect = mru.estimatedVirtualRect
        let orientation: Orientation = rect.width >= rect.height ? .h : .v
        if parent.children.count == 1 {
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

    @MainActor
    private func floatingBindingData(windowId: UInt32) -> BindingData {
        if !windowsFloatedByLayout.contains(windowId) {
            windowsFloatedByLayout.append(windowId)
        }
        return BindingData(parent: floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}

extension TreeNode {
    /// The rect this node would get from layoutRecursive, computed from the tree alone (weights, orientations,
    /// accordion), ignoring gaps. Used where the last applied rect is stale or missing: hidden workspaces and
    /// rebuilds between layout passes
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
    for (workspace, before) in layoutsBeforeReload {
        workspace.layoutOverride = nil
        if workspace.layout != before {
            workspace.applyLayout(workspace.layout)
        }
    }
}
