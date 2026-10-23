import AppKit
import Common

struct FocusAppCommand: Command {
    let args: FocusAppCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let app = resolveFocusAppTarget(args.target) else {
            return .fail(io.err("Can't find \(args.target.description). Use an app's bundle id (see 'aerospace list-apps') or its name"))
        }
        let windows = Workspace.all.flatMap(\.allLeafWindowsRecursive).filter {
            $0.app.rawAppBundleId == app.bundleId && $0.isReachableByFocusApp
        }
        let lastUsed = windows.lazy.compactMap { ($0.app as? MacApp)?.lastNativeFocusedWindowId }.first
        switch focusAppAction(windows: windows.map(\.windowId), focused: focus.windowOrNil?.windowId, lastUsed: lastUsed) {
            case .focus(let windowId):
                return .from(bool: windows.first { $0.windowId == windowId }?.focusWindow() == true)
            case .stay:
                return .succ
            case .open:
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
                return .succ
        }
    }
}

enum FocusAppAction: Equatable {
    /// Switch to the window's workspace and focus it
    case focus(windowId: UInt32)
    /// The app's only window already has focus
    case stay
    /// Launch the app, or reopen it when it runs without a window AeroSpace can focus (like clicking its Dock icon)
    case open
}

/// - Parameters:
///   - windows: the app's windows across all workspaces, in a stable order (workspace, then tree order)
///   - focused: the focused window
///   - lastUsed: the app's most recently focused window
func focusAppAction(windows: [UInt32], focused: UInt32?, lastUsed: UInt32?) -> FocusAppAction {
    guard let first = windows.first else { return .open }
    if let focused, let index = windows.firstIndex(of: focused) {
        return windows.count == 1 ? .stay : .focus(windowId: windows[(index + 1) % windows.count])
    }
    if let lastUsed, windows.contains(lastUsed) { return .focus(windowId: lastUsed) }
    return .focus(windowId: first)
}

extension Window {
    /// Minimized windows and windows of hidden apps can't be focused, so the app gets reopened instead
    fileprivate var isReachableByFocusApp: Bool {
        switch windowParentCases {
            case .tilingContainer, .floatingWindowsContainer, .macosFullscreenWindowsContainer: true
            case .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer, .macosPopupWindowsContainer, .unbound: false
        }
    }
}

extension FocusAppTarget {
    var description: String {
        switch self {
            case .app(let app): "app '\(app)'"
            case .defaultBrowser: "the default browser"
            case .defaultTerminal: "a terminal app"
        }
    }

    var focusAppCommand: String {
        switch self {
            case .app(let app):
                "focus-app " + (app.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) } ? app : app.contains("'") ? "\"\(app)\"" : "'\(app)'")
            case .defaultBrowser: "focus-app --default-browser"
            case .defaultTerminal: "focus-app --default-terminal"
        }
    }
}

/// The target of a command that is exactly one `focus-app`
func parseFocusAppTarget(_ command: String) -> FocusAppTarget? {
    guard case .cmd(.cmd(let parsed as FocusAppCommand)) = parseCommand(command, allowExecAndForget: false, allowEval: false) else { return nil }
    return parsed.args.target
}

// MARK: - Finding apps

struct ResolvedApp: Equatable {
    let bundleId: String
    let url: URL
}

/// Looks the app up the way it is installed right now, so the default browser and terminal follow system changes
@MainActor func resolveFocusAppTarget(_ target: FocusAppTarget) -> ResolvedApp? {
    switch target {
        case .defaultBrowser:
            return URL(string: "https://example.com")
                .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
                .flatMap(resolvedApp(at:))
        case .defaultTerminal:
            return knownTerminalBundleIds.lazy
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .compactMap(resolvedApp(at:))
                .first
        case .app(let app):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                return resolvedApp(at: url)
            }
            let running = NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier?.caseInsensitiveCompare(app) == .orderedSame ||
                    $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame
            }
            if let url = running?.bundleURL { return resolvedApp(at: url) }
            let fileName = app.hasSuffix(".app") ? app : app + ".app"
            return installedAppUrls().first { $0.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame }
                .flatMap(resolvedApp(at:))
    }
}

/// In the order `--default-terminal` picks them. Terminal.app ships with macOS, so it's the fallback
let knownTerminalBundleIds = [
    "so.stencil.tern",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "org.alacritty",
    "com.github.wez.wezterm",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "com.apple.Terminal",
]

private func resolvedApp(at url: URL) -> ResolvedApp? {
    Bundle(url: url)?.bundleIdentifier.map { ResolvedApp(bundleId: $0, url: url) }
}

/// .app bundles in the standard application folders, one level deep
func installedAppUrls() -> [URL] {
    let folders = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path,
    ]
    let apps = folders.flatMap { folder in
        // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink with the hidden flag
        let children = (try? FileManager.default.contentsOfDirectory(at: URL(filePath: folder), includingPropertiesForKeys: nil)) ?? []
        return children.filter { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix(".") }
    }
    return apps + [URL(filePath: "/System/Library/CoreServices/Finder.app")]
}
