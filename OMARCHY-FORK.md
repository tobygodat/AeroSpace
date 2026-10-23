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

## Super key: Caps Lock, Right Command, or both. Built; not yet tried inside the running WM

Bindings can use `super` as a modifier (`super-b`, `super-shift-1`, `super-ctrl-tab`). `super-key` in the config says
which physical key Super is:

| `super-key` | Super is | Handled by |
|---|---|---|
| `'caps-lock'` (default) | Caps Lock held. Tapped alone (released within 0.5 s, nothing else pressed) it's Escape | hidutil remaps Caps Lock to F18; an event tap turns F18 into Super |
| `'right-cmd'` | Right Command held. Left Command stays Command | the event tap |
| `'caps-lock-or-right-cmd'` | Either one. The first pressed owns Super until it's released; the other does nothing meanwhile (no stacking, no Command, no Caps Lock) | both |
| `'alt'`, `'cmd'` | That modifier | Carbon hotkeys, like any `alt-*` binding |

Super is a modifier of its own, never ctrl+alt+cmd, so `super-shift-x`, `super-ctrl-x` and `ctrl-alt-cmd-x` are three
different shortcuts. While Super is held, every key press is a Super chord: it runs its binding or does nothing, and the
app never sees it. Nothing starts until some binding uses `super`, so a config with only `alt-*` bindings works as
before and Caps Lock stays Caps Lock. While Super is Option or Command, `super-b` is `alt-b` (or `cmd-b`): one binding,
and writing both in one mode is an error. `enable off` turns Super off too, and gives Caps Lock back.

Settings → **Super key** picks the key, shows whether Super is on, and has **Convert to ◆ Super**: every `alt-` in a
binding key becomes `super-` (only the key text changes; commands and comments stay), with Undo. The Omarchy preset
now writes `super-*` bindings. Shortcuts show Super as ◆. The recorder records it: Super runs while recording, even
before any binding uses it, and when Super is Option or Command, that modifier is recorded as Super.

Safety:
- The tap runs on its own thread, so a busy main thread never holds up typing.
- The remap is per keyboard: each keeps its own Modifier Keys remaps (a PC keyboard with ⌥ and ⌘ swapped stays
  swapped). Before it, each keyboard's Caps Lock mapping is saved to
  `~/Library/Application Support/AeroSpace/caps-lock-remap.json`. It's put back on quit (also on SIGTERM), when the
  setting changes, and at the next launch after a crash, before AeroSpace waits for Accessibility. A keyboard plugged
  in later gets the remap within 10 seconds. If Caps Lock is on when the remap starts, it's turned off first.
- If macOS disables the tap and it can't be turned back on, or Accessibility is revoked, Caps Lock is restored and the
  menu shows "Super key is off" with Try again. If hidutil can't restore it, a working tap stays on so Caps Lock is
  still Super, the menu shows "Caps Lock is stuck", and AeroSpace retries every 2 seconds.
- Undo by hand: restart the Mac, or `hidutil property --set '{"UserKeyMapping":[]}'` (which also clears other remaps
  until the next login).
- Permissions: Accessibility, which AeroSpace already needs. Some macOS versions also ask for Input Monitoring.
- In password fields (Secure Input) macOS hides keys from event taps, so Super doesn't work there and Caps Lock types
  nothing. If Super is released while a password field has focus, the next key press notices and goes to the app.

| File | What |
|---|---|
| `Sources/AppBundle/config/keysMap.swift` | `HotkeyModifiers`: the binding modifiers, Super included |
| `Sources/AppBundle/config/superKey.swift` | `SuperKey` (`super-key`) and its parser |
| `Sources/AppBundle/superKey/SuperKeyOwnership.swift` | Pure state machine: who owns Super, tap vs hold, repeats, chords |
| `Sources/AppBundle/superKey/CapsLockRemap.swift` | hidutil remap and restore, with an injected runner |
| `Sources/AppBundle/superKey/SuperKeyTap.swift` | The CGEventTap on its own thread |
| `Sources/AppBundle/superKey/SuperKeyRuntime.swift` | Starts and stops tap and remap (reload, enable/disable, recording), watchdog, fail-safe |
| `Sources/AppBundle/config/editableSuperKey.swift` | Minimal-diff edits: `super-key`, and ⌥ → Super conversion |
| `Sources/AppBundle/ui/settings/SuperKeyPane.swift` | The Super key pane and the menu warning |

Preview: `swift run KeybindingEditorPreview --config /tmp/scratch.toml --pane super-key [--super-status on|failed]`.

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
