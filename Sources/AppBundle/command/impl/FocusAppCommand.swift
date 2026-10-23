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
        // AeroSpace keeps its focus while macOS has an app it doesn't manage in front, like AeroSpace's own settings window
        let focused = focus.windowOrNil.flatMap { $0.app.pid == frontmostAppPid ? $0.windowId : nil }
        let lastUsed = windows.filter { $0.lastNativeFocus > 0 }.max { $0.lastNativeFocus < $1.lastNativeFocus }?.windowId
        switch focusAppAction(windows: windows.map(\.windowId), focused: focused, lastUsed: lastUsed) {
            case .focus(let windowId):
                guard let window = windows.first(where: { $0.windowId == windowId }) else { return .fail }
                if window.parent is MacosHiddenAppsWindowsContainer { (window.app as? MacApp)?.nsApp.unhide() }
                // The session brings macOS along only when AeroSpace's focus changes
                let isAlreadyAeroSpaceFocus = focus.windowOrNil == window
                guard window.focusWindow() else { return .fail }
                if isAlreadyAeroSpaceFocus { window.nativeFocus() }
                return .succ
            case .stay:
                return .succ
            case .open:
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == app.bundleId }
                NSWorkspace.shared.openApplication(at: running?.bundleURL ?? app.url, configuration: configuration)
                return .succ
        }
    }
}

/// Tests stand in for macOS with `appForTests`
@MainActor private var frontmostAppPid: Int32? {
    appForTests?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
}

enum FocusAppAction: Equatable {
    /// Switch to the window's workspace and focus it
    case focus(windowId: UInt32)
    /// The app's only window already has focus
    case stay
    /// Launch the app, or reopen it when all its windows are minimized or it has none (like clicking its Dock icon)
    case open
}

/// - Parameters:
///   - windows: the app's windows across all workspaces, in a stable order (workspace, then tree order)
///   - focused: the focused window, when macOS has its app in front
///   - lastUsed: the most recently focused of `windows`
func focusAppAction(windows: [UInt32], focused: UInt32?, lastUsed: UInt32?) -> FocusAppAction {
    guard let first = windows.first else { return .open }
    if let focused, let index = windows.firstIndex(of: focused) {
        return windows.count == 1 ? .stay : .focus(windowId: windows[(index + 1) % windows.count])
    }
    if let lastUsed, windows.contains(lastUsed) { return .focus(windowId: lastUsed) }
    return .focus(windowId: first)
}

extension Window {
    /// Minimized windows can't be focused, so the app gets reopened instead. Windows of hidden apps stay on their workspace
    fileprivate var isReachableByFocusApp: Bool {
        switch windowParentCases {
            case .tilingContainer, .floatingWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: true
            case .macosMinimizedWindowsContainer, .macosPopupWindowsContainer, .unbound: false
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
