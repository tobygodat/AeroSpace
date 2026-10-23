# Omarchy-style AeroSpace fork: roadmap

Goal: one app that tiles like Hyprland/Omarchy, launches apps like Raycast, and lets you
change every hotkey from a GUI instead of hand-editing TOML.

## Where things stand

- Base: branch `omarchy-base`, cut from upstream tag `v0.21.3-Beta` (the version installed on this Mac).
- Builds with Command Line Tools only (Swift 6.3.3):
  `swift build --product AeroSpaceApp` → `.build/debug/AeroSpaceApp`.
  Don't use `./build-debug.sh`; it needs bash 5 (`brew install bash`).
- Upstream `main` needs Swift 6.4 / Xcode 27. Rebasing onto newer releases, and producing a
  signed `.app` with `xcodebuild`, requires installing Xcode.
- Raycast is closed source, so it can't be forked. The launcher is built from scratch below.

## Phase 1: Keybinding editor (the "GUI for hotkeys"). Built; not yet tried inside the running WM

Menu bar → **Keybindings…** (⌘K) opens a window listing every binding per mode. Click a shortcut and
press the new keys (Esc cancels), use ⚡ to pick an action (Open app…, workspaces, window commands), or
type a command. **Presets** loads Omarchy with ⌥ or ⌘ as Super. Duplicate shortcuts and invalid commands
are flagged inline and block Save. Save edits only the changed lines of the config, backs up the original
once to `<config>.bak-keybindings`, and reloads.

| File | What |
|---|---|
| `Sources/AppBundle/config/editableBindings.swift` | Read/rewrite `[mode.*.binding]` tables; minimal-diff TOML edits, verified by re-parsing |
| `Sources/AppBundle/ui/keybindings/KeybindingEditorModel.swift` | Load, validate, record shortcuts (pauses AeroSpace hotkeys while recording), save + reload |
| `Sources/AppBundle/ui/keybindings/KeybindingEditorView.swift` | The window, rows, action menu, menu-bar button |
| `Sources/AppBundle/ui/keybindings/keybindingPresets.swift` | Omarchy presets (detects default browser and Ghostty/kitty/Alacritty/WezTerm) |
| `Sources/KeybindingEditorPreview/main.swift` | Dev harness: editor on a scratch config, optional `--demo` and `--snapshot out.png` |
| `Sources/KeybindingEditorTests/` | swift-testing suite; run `./test-keybinding-editor.sh` |

Try it without touching the running AeroSpace:

```sh
cp ~/.aerospace.toml /tmp/scratch.toml
swift run KeybindingEditorPreview --config /tmp/scratch.toml
```

Original design notes:

| Piece | Where it hooks in |
|---|---|
| "Keybindings…" menu item | `Sources/AppBundle/ui/MenuBar.swift` (next to `openConfigButton`) |
| Settings window scene | `Sources/AeroSpaceApp/AeroSpaceApp.swift`: add a SwiftUI `Window(id: "keybindings")` |
| Read current bindings | `config.modes[mode].bindings`, a `[String: HotkeyBinding]` (`Sources/AppBundle/config/HotkeyBinding.swift`) |
| Record a shortcut | `NSEvent.addLocalMonitorForEvents(.keyDown)` while the window is focused; call `resetHotKeys()` during recording so AeroSpace doesn't swallow the keys, then `activateMode_nonCancellable(activeMode)` to restore |
| Pick an action | Dropdown of AeroSpace commands, plus friendly actions: "Open app…" (→ `exec-and-forget open -a`), "Switch to workspace N", "Move window to workspace N" |
| Save | Rewrite only the `[mode.*.binding]` tables in the config file (keep every other key), then `reloadConfig_nonCancellable` |
| Conflict warnings | Flag duplicates, and Option+arrow / Option+letter clashes with text editing |
| Presets | "Omarchy (Option)", "Omarchy (Cmd)", "Omarchy (Hyper)", "AeroSpace default" |

## App hotkeys: focus or launch. Built; not yet tried inside the running WM

`focus-app` jumps to an app wherever it is: it switches to the workspace of the app's most recently used window and
focuses it. Pressing it again while the app is focused cycles through the app's windows across workspaces (one window:
nothing happens). An app that runs without a window AeroSpace can focus (minimized, hidden) gets the Dock-click "reopen";
an app that isn't running is launched.

```toml
alt-b = 'focus-app --default-browser'        # the system's default browser, looked up on every press
alt-enter = 'focus-app --default-terminal'   # first installed of Tern, Ghostty, kitty, Alacritty, WezTerm, iTerm2, Warp, Terminal
alt-shift-m = 'focus-app com.apple.Music'    # a bundle id, or an app name
```

Settings → **Apps** in the keybinding editor window lists app shortcuts: app (installed apps with icons, or Default
browser / Default terminal), recorded shortcut, and an optional **home workspace**. A home workspace is a plain
`[[on-window-detected]]` rule (`if.app-id` + `run = 'move-node-to-workspace N'`), so new windows of the app open there;
other rules are never shown or touched. "Suggested" offers Omarchy's launch-or-focus apps for the configured Super key
(the modifiers of the `workspace 1` binding); when those keys already open an app, the suggestion focuses that app instead.
While Option is Super, a row notes the character the shortcut takes away (⌥B types ∫). Both panes share one Save.

| File | What |
|---|---|
| `Sources/Common/cmdArgs/impl/FocusAppCmdArgs.swift` | `focus-app` arguments (`<app>`, `--default-browser`, `--default-terminal`) |
| `Sources/AppBundle/command/impl/FocusAppCommand.swift` | Finds the app's windows, `focusAppAction` decides focus / cycle / open, app lookup |
| `Sources/AppBundle/config/homeWorkspaceRules.swift` | Read/rewrite home-workspace rules; minimal-diff TOML edits, verified by re-parsing |
| `Sources/AppBundle/ui/settings/appShortcuts.swift` | Apps pane rows derived from the editor model, suggestions, Super key, Option-character note, installed apps |
| `Sources/AppBundle/ui/settings/AppShortcutsPane.swift` | The pane and the app picker |
| `docs/aerospace-focus-app.adoc` | Command docs |

The Omarchy presets now use `focus-app` for Super+B and Super+Return (Super+Shift+B and Super+Shift+Return open a new
window), plus Super+Shift+M for Spotify or Music and, when installed, Signal (⇧G), Obsidian (⇧O) and 1Password (⇧/).

```sh
cp ~/.aerospace.toml /tmp/scratch.toml
swift run KeybindingEditorPreview --config /tmp/scratch.toml --pane apps
```

With Command Line Tools 27, build and test against the 26.5 SDK (the 27 SDK's SwiftUI macros have no CLT plugin):
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`, and add
`-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` to
`./test-keybinding-editor.sh`.

## Phase 2: Launcher (replaces Raycast for apps)

- New command `launcher`, bound to Super+Space by default.
- UI: floating search panel. Reuse `Sources/AppBundle/ui/NSPanelHud.swift`.
- Sources: apps in `/Applications`, `/System/Applications`, `~/Applications` (Spotlight `NSMetadataQuery`
  for `kMDItemContentType == com.apple.application-bundle`), fuzzy match, Enter to open.
- Later: run any AeroSpace command by name, recent windows, calculator, custom script commands.

## Phase 3: Omarchy polish

- Clickable workspace bar (Waybar-style 1–5 indicator) built on `MenuBarLabel.swift`.
- "Keybindings" cheat-sheet overlay (Omarchy's Super+K).
- Super+Space menu (Omarchy menu) for theme, gaps toggle, reload, and service-mode actions.

## Shipping it to yourself. Done

`./package-app.sh --install` builds `AeroSpace Omarchy.app` (bundle id `dev.tobygodat.aerospace-omarchy`) from the
SwiftPM release build and installs it to `~/Applications`. No Xcode needed. It keeps AeroSpace's socket name, so the
Homebrew `aerospace` CLI talks to it.

- Quit the stock AeroSpace first, and turn off its login item. Both apps register the same hotkeys and socket.
- The app is signed ad-hoc, so macOS drops its Accessibility permission on every rebuild: toggle it off and on
  again in System Settings → Privacy & Security → Accessibility. Set `CODESIGN_IDENTITY` to a self-signed code
  signing certificate to avoid this.
- The menu shows version `0.0.0-SNAPSHOT` (the generated version files aren't stamped without `generate.sh`), so the
  CLI warns about a version mismatch when a command fails.
