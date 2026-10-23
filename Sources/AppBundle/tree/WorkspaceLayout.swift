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
    /// Idempotent: applying the current layout again changes nothing.
    @MainActor
    func applyLayout(_ target: WorkspaceLayout) {
        die("TODO(AERO-4 engine): applyLayout")
    }

    /// Where a new tiling window goes on this workspace. `window` is already unbound, or nil for a window that is
    /// being registered (then only `windowId` is known).
    /// - tiles: next to the most recent window in its container (AeroSpace's behavior)
    /// - dwindle: splits the most recent window's area along its longer side: the window is wrapped in a new
    ///   container oriented by `estimatedVirtualRect`, and the new window becomes its second child
    /// - floating: the floating container; the window id is appended to `windowsFloatedByLayout`
    @MainActor
    func bindingDataForNewTilingWindow(windowId: UInt32, window: Window?) -> BindingData {
        die("TODO(AERO-4 engine): bindingDataForNewTilingWindow")
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
