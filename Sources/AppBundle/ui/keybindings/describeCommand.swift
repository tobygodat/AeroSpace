import Common
import Foundation

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
        case "workspace-layout":
            if last == "next" { return ("Cycle workspace layout", .windows) }
            let titles = args.compactMap { WorkspaceLayout(rawValue: $0)?.title }
            return ("Workspace layout: \(titles.isEmpty ? last : titles.joined(separator: " / "))", .windows)
        case "move-node-to-monitor": return ("Move window to \(last) monitor", .monitors)
        case "move-workspace-to-monitor": return ("Move workspace to \(last) monitor", .monitors)
        case "focus-monitor": return ("Focus \(last) monitor", .monitors)
        case "mode": return ("Enter \(last) mode", .modes)
        case "reload-config": return ("Reload config", .modes)
        case "enable": return ("Toggle tiling", .modes)
        default: return (command, .other)
    }
}

private func describeShell(_ script: String) -> String {
    let script = script.trimmingCharacters(in: .whitespaces)
    if let app = firstMatch(#"tell application "([^"]+)""#, script) { return "Open \(app)" }
    if script.hasPrefix("open") {
        if let app = firstMatch(#"-n?a\s+"([^"]+)""#, script) ?? firstMatch(#"-n?a\s+([^\s"]+)"#, script) {
            return script.contains("--incognito") || script.contains("--private") ? "Open \(app) (private)" : "Open \(app)"
        }
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
