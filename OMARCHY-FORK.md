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

## Workspace layouts: tiles, dwindle, floating. Built; not yet tried inside the running WM

Each workspace has a layout. **Tiles** is upstream AeroSpace (new windows join the focused window's container).
**Dwindle** is Hyprland's default: a new window splits the focused window along its longer side, so windows spiral.
**Floating** floats every window; switching back tiles exactly the windows the layout floated, and leaves dialogs
and `layout floating` windows alone. `workspace-layout next` cycles tiles → dwindle → floating, and the Omarchy
presets bind it to Super ⇧ T. Settings → **Layouts** picks the default, adds per-workspace overrides and records the
cycle shortcut; Save rewrites only those lines of the config and reloads.

```toml
default-workspace-layout = 'dwindle'   # tiles (default) | dwindle | floating

[workspace-layout]
3 = 'floating'                          # per-workspace override
```

| File | What |
|---|---|
| `Sources/Common/model/WorkspaceLayout.swift` | The enum and the `next` cycle |
| `Sources/AppBundle/tree/WorkspaceLayout.swift` | Where new windows go per layout, `applyLayout` (rebuilds the tree), re-apply after `reload-config` |
| `Sources/AppBundle/command/impl/WorkspaceLayoutCommand.swift` | `workspace-layout [--workspace <name>] (tiles\|dwindle\|floating\|next)...` |
| `Sources/AppBundle/config/parseWorkspaceLayout.swift`, `editableWorkspaceLayouts.swift` | Parse the two keys; minimal-diff rewrite for the pane |
| `Sources/AppBundle/ui/settings/LayoutsPane.swift`, `LayoutsPaneModel.swift` | The Settings pane (`--pane layouts` in the preview harness) |
| `Sources/WorkspaceLayoutTests/` | swift-testing suite with ASCII frame diagrams; run `./test-workspace-layouts.sh` |
| `docs/aerospace-workspace-layout.adoc`, `docs/guide.adoc` | Command and config docs |

Scrolling (PaperWM/niri style) is designed but not built: off-view columns can be parked with a 1 px sliver on
screen, the same trick `hideInCorner` uses, since macOS only pulls a window back when none of it is visible.

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
