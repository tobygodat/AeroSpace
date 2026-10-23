import AppKit
import Common

/// Groups shown in the keybinding editor, in display order
enum KeybindingCategory: String, CaseIterable {
    case unassigned = "Unassigned"
    case apps = "Apps"
    case windows = "Windows"
    case focus = "Focus & move"
    case workspaces = "Workspaces"
    case monitors = "Monitors"
    case modes = "Modes & config"
    case other = "Other"
}

/// A human-readable title for a binding's commands, e.g. "workspace 1" → "Switch to workspace 1"
func describeCommands(_ commands: [String]) -> (title: String, category: KeybindingCategory) {
    let described = commands.map(describeCommand)
    guard let first = described.first else { return ("No action", .unassigned) }
    if described.count == 1 { return first }
    return (described.map(\.title).joined(separator: ", then "), first.category)
}

private func describeCommand(_ raw: String) -> (title: String, category: KeybindingCategory) {
    let command = raw.trimmingCharacters(in: .whitespaces)
    if command.hasPrefix("exec-and-forget") {
        return (describeShell(String(command.dropFirst("exec-and-forget".count))), .apps)
    }
    if command.hasPrefix("focus-app"), let target = parseFocusAppTarget(command) {
        return switch target {
            case .defaultBrowser: ("Go to browser", .apps)
            case .defaultTerminal: ("Go to terminal", .apps)
            case .app(let app): ("Go to \(NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)?.deletingPathExtension().lastPathComponent ?? app)", .apps)
        }
    }
    let words = command.split(separator: " ").map(String.init)
    guard let name = words.first else { return ("No action", .unassigned) }
    let args = words.dropFirst().filter { !$0.hasPrefix("--") }
    let last = args.last ?? ""
    switch name {
        case "workspace":
            switch last {
                case "next": return ("Next workspace", .workspaces)
                case "prev": return ("Previous workspace", .workspaces)
                default: return ("Switch to workspace \(last)", .workspaces)
            }
        case "workspace-back-and-forth": return ("Last used workspace", .workspaces)
        case "move-node-to-workspace": return ("Move window to workspace \(last)", .workspaces)
        case "focus": return ("Focus \(last)", .focus)
        case "move": return ("Move window \(last)", .focus)
        case "swap": return ("Swap window \(last)", .focus)
        case "join-with": return ("Join with \(last)", .focus)
        case "resize":
            return last.hasPrefix("-") ? ("Shrink window", .windows) : ("Grow window", .windows)
        case "close": return ("Close window", .windows)
        case "close-all-windows-but-current": return ("Close other windows", .windows)
        case "fullscreen": return ("Toggle fullscreen", .windows)
        case "macos-native-fullscreen": return ("Toggle macOS fullscreen", .windows)
        case "macos-native-minimize": return ("Minimize window", .windows)
        case "flatten-workspace-tree": return ("Reset layout", .windows)
        case "balance-sizes": return ("Balance window sizes", .windows)
        case "layout":
            let targets = Set(args)
            if targets.contains("floating") { return ("Toggle floating", .windows) }
            if targets.contains("accordion") { return ("Toggle tiles / accordion", .windows) }
            if targets.contains("horizontal") || targets.contains("vertical") { return ("Toggle split direction", .windows) }
            return ("Change layout", .windows)
        case "move-node-to-monitor": return ("Move window to \(last) monitor", .monitors)
        case "move-workspace-to-monitor": return ("Move workspace to \(last) monitor", .monitors)
        case "focus-monitor": return ("Focus \(last) monitor", .monitors)
        case "mode": return ("Enter \(last) mode", .modes)
        case "reload-config": return ("Reload config", .modes)
        case "enable": return ("Toggle tiling", .modes)
        default: return (command, .other)
    }
}

/// The app an `exec-and-forget` binding opens with `open -a` or AppleScript, e.g. "Google Chrome"
func appOpened(by commands: [String]) -> String? {
    guard let command = commands.singleOrNil()?.trimmingCharacters(in: .whitespaces), command.hasPrefix("exec-and-forget") else { return nil }
    return appOpened(byScript: String(command.dropFirst("exec-and-forget".count)).trimmingCharacters(in: .whitespaces))
}

private func appOpened(byScript script: String) -> String? {
    if let app = firstMatch(#"tell application "([^"]+)""#, script) { return app }
    guard script.hasPrefix("open") else { return nil }
    return firstMatch(#"-n?a\s+"([^"]+)""#, script) ?? firstMatch(#"-n?a\s+([^\s"]+)"#, script)
}

private func describeShell(_ script: String) -> String {
    let script = script.trimmingCharacters(in: .whitespaces)
    if let app = appOpened(byScript: script) {
        return script.contains("--incognito") || script.contains("--private") ? "Open \(app) (private)" : "Open \(app)"
    }
    if script.hasPrefix("open") {
        if let file = firstMatch(#"-t\s+(\S+)"#, script) { return "Edit \((file as NSString).lastPathComponent)" }
        if let target = firstMatch(#"^open\s+(\S+)$"#, script) {
            return target == "~" ? "Open home folder" : "Open \(target)"
        }
    }
    return "Run \(script)"
}

private func firstMatch(_ pattern: String, _ text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}
