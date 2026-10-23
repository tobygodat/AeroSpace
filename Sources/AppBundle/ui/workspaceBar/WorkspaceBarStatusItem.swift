import AppKit
import Common

@MainActor
final class WorkspaceBarStatusItem {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 0)
    private let view: WorkspaceBarView

    init(icon: @escaping (WorkspaceBarApp) -> NSImage?, onSelect: @escaping (String) -> Void) {
        view = WorkspaceBarView(icon: icon, onSelect: onSelect)
        statusItem.autosaveName = "AeroSpaceWorkspaceBar"
        if let button = statusItem.button {
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
        }
    }

    func show(_ items: [WorkspaceBarItem], appIcons: Bool) {
        view.show(items, appIcons: appIcons, maxWidth: workspaceBarMaxWidth())
        if statusItem.length != view.barLayout.size.width {
            statusItem.length = view.barLayout.size.width
        }
        statusItem.isVisible = true
    }

    /// Hidden rather than removed: removing a status item forgets where the user ⌘-dragged it
    func hide() {
        statusItem.isVisible = false
    }
}

@MainActor private var shownBar: WorkspaceBarStatusItem? = nil
@MainActor private var appIconCache: [String: NSImage] = [:]

/// Shows, updates, or hides the workspace bar. Returns whether it's shown
@MainActor func updateWorkspaceBar() -> Bool {
    guard TrayMenuModel.shared.isEnabled && config.workspaceBar.enabled else {
        shownBar?.hide()
        return false
    }
    let bar = shownBar ?? WorkspaceBarStatusItem(icon: workspaceBarAppIcon, onSelect: focusWorkspaceFromBar)
    shownBar = bar
    bar.show(workspaceBarItems(liveWorkspaceBarWorkspaces(), persistent: config.persistentWorkspaces), appIcons: config.workspaceBar.appIcons)
    return true
}

/// Half the menu bar right of the notch, or a quarter of a menu bar without one, on the narrowest display
@MainActor func workspaceBarMaxWidth() -> CGFloat {
    NSScreen.screens.map { ($0.auxiliaryTopRightArea?.width ?? $0.frame.width / 2) / 2 }.min() ?? .infinity
}

@MainActor func liveWorkspaceBarWorkspaces() -> [WorkspaceBarWorkspace] {
    if Workspace.all.isEmpty { return [] } // Before startup; reading `focus` would create a workspace
    let focusedWorkspace = focus.workspace
    return Workspace.all.map { workspace in
        WorkspaceBarWorkspace(
            name: workspace.name,
            isFocused: workspace == focusedWorkspace,
            isVisible: workspace.isVisible,
            windowApps: workspace.allLeafWindowsRecursive.map { window in
                let app = window.app
                let id = app.rawAppBundleId ?? "pid:\(app.pid)"
                return WorkspaceBarApp(id: id, name: app.name ?? id, pid: app.pid)
            },
        )
    }
}

@MainActor func workspaceBarAppIcon(_ app: WorkspaceBarApp) -> NSImage? {
    if let cached = appIconCache[app.id] { return cached }
    let icon = NSRunningApplication(processIdentifier: app.pid)?.icon
    appIconCache[app.id] = icon
    return icon
}

@MainActor private func focusWorkspaceFromBar(_ name: String) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: name).focusWorkspace() }
    }
}
