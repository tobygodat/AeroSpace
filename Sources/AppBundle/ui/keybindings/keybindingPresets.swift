import AppKit
import Common

struct KeybindingPreset: Identifiable {
    let name: String
    /// Bindings for the 'main' mode, in display order
    let bindings: [(key: String, command: String)]

    var id: String { name }
}

@MainActor func keybindingPresets() -> [KeybindingPreset] {
    [
        KeybindingPreset(name: "Omarchy · ⌥ as Super", bindings: omarchyBindings(superKey: "alt")),
        KeybindingPreset(name: "Omarchy · ⌘ as Super", bindings: omarchyBindings(superKey: "cmd")),
    ]
}

/// Mirrors the Hyprland bindings shipped by Omarchy (https://github.com/basecamp/omarchy), translated to AeroSpace commands
@MainActor func omarchyBindings(superKey s: String) -> [(key: String, command: String)] {
    var result: [(key: String, command: String)] = [
        ("\(s)-enter", presetTerminalCommand()),
        ("\(s)-b", presetBrowserCommand()),
        ("\(s)-shift-b", presetBrowserCommand()),
        ("\(s)-shift-f", "exec-and-forget open ~"),
        ("\(s)-w", "close"),
        ("\(s)-q", "close"),
        ("\(s)-f", "fullscreen"),
        ("\(s)-t", "layout floating tiling"),
        ("\(s)-shift-t", "workspace-layout next"),
        ("\(s)-j", "layout horizontal vertical"),
        ("\(s)-l", "layout tiles accordion"),
        ("\(s)-m", "macos-native-minimize"),
        ("\(s)-left", "focus left"),
        ("\(s)-right", "focus right"),
        ("\(s)-up", "focus up"),
        ("\(s)-down", "focus down"),
        ("\(s)-shift-left", "move left"),
        ("\(s)-shift-right", "move right"),
        ("\(s)-shift-up", "move up"),
        ("\(s)-shift-down", "move down"),
        ("\(s)-minus", "resize smart -50"),
        ("\(s)-equal", "resize smart +50"),
    ]
    for n in 1 ... 9 {
        result.append(("\(s)-\(n)", "workspace \(n)"))
    }
    for n in 1 ... 9 {
        result.append(("\(s)-shift-\(n)", "move-node-to-workspace --focus-follows-window \(n)"))
    }
    result += [
        ("\(s)-tab", "workspace --wrap-around next"),
        ("\(s)-shift-tab", "workspace --wrap-around prev"),
        ("\(s)-ctrl-tab", "workspace-back-and-forth"),
        ("\(s)-s", "workspace S"),
        ("\(s)-shift-s", "move-node-to-workspace S"),
        ("\(s)-shift-ctrl-left", "move-node-to-monitor --focus-follows-window left"),
        ("\(s)-shift-ctrl-right", "move-node-to-monitor --focus-follows-window right"),
        ("\(s)-ctrl-left", "move-workspace-to-monitor left"),
        ("\(s)-ctrl-right", "move-workspace-to-monitor right"),
        ("\(s)-shift-semicolon", "mode service"),
    ]
    return result
}

@MainActor func presetTerminalCommand() -> String {
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "so.stencil.tern") != nil {
        return "exec-and-forget open -a Tern"
    }
    let terminals: [(bundleId: String, name: String)] = [
        ("com.mitchellh.ghostty", "Ghostty"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
        ("com.github.wez.wezterm", "WezTerm"),
    ]
    for terminal in terminals where NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleId) != nil {
        return "exec-and-forget open -na \"\(terminal.name)\""
    }
    return openAppCommand(name: "Terminal")
}

@MainActor func presetBrowserCommand() -> String {
    let defaultBrowser = URL(string: "https://example.com")
        .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }?
        .deletingPathExtension().lastPathComponent
    return openAppCommand(name: defaultBrowser ?? "Safari")
}

/// The command for "open this app". Opens a new window for apps where that's what Omarchy's launch bindings do
func openAppCommand(name: String) -> String {
    let newWindowArgBrowsers = ["Google Chrome", "Chromium", "Brave Browser", "Microsoft Edge", "Vivaldi", "Firefox", "Zen"]
    if newWindowArgBrowsers.contains(name) {
        return "exec-and-forget open -na \"\(name)\" --args --new-window"
    }
    if name == "Terminal" {
        return #"exec-and-forget osascript -e 'tell application "Terminal" to do script ""' -e 'tell application "Terminal" to activate'"#
    }
    return "exec-and-forget open -a \"\(name)\""
}
