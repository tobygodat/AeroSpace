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

Menu bar → **Settings…** (⌘K) opens a window listing every binding per mode. Click a shortcut and
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

## Workspace bar. Built; not yet tried inside the running WM

The menu bar shows one group per workspace: its name and the icons of the apps on it, one icon per app. Up to 3
icons, then "+N". Persistent workspaces always show, even when empty; other workspaces show while they have windows or
are on a monitor. The focused workspace gets a filled pill, a workspace shown on another monitor an outlined one, and
empty ones are dimmed. Click a group to switch to it. While the bar is shown, the AeroSpace menu item shrinks to a
glyph (or the binding-mode letter). macOS hides a status item that doesn't fit instead of truncating it, so when the
bar is wider than half the menu bar right of the notch (a quarter of a menu bar without one), it shows one icon per
workspace, then names only.

**Settings… → Workspaces** sets the number of persistent workspaces (1–9) and the two bar options, with a live preview
of the bar. Other persistent workspaces (like the A–Z of older default configs) are listed under the count with a
Remove button. Every change is written to the config right away through `KeybindingEditorModel.editConfig`: it
applies only the field you changed to the file as it is on disk, refuses while there are unsaved binding edits, writes
one change at a time, backs up once to `<config>.bak-keybindings`, then the config reloads. Raising the count adds
missing Super+N / Super+Shift+N bindings for the new workspaces by copying the modifiers and flags of the ones you
already have. It never removes bindings. A `persistent-workspaces` list with comments inside it is left for you to edit
by hand. A config-version 1 config becomes version 2 with only 1…count persistent.

```toml
persistent-workspaces = ["1", "2", "3", "4", "5"]   # the count in Settings → Workspaces
workspace-bar.enabled = true                       # false: the classic AeroSpace menu bar label
workspace-bar.app-icons = true                     # false: workspace names only
```

| File | What |
|---|---|
| `Sources/AppBundle/ui/workspaceBar/WorkspaceBarModel.swift` | Grouping and layout as plain functions, and click hit testing |
| `Sources/AppBundle/ui/workspaceBar/WorkspaceBarView.swift` | Draws the bar and handles clicks; `InlineWorkspaceBar` reuses it in Settings |
| `Sources/AppBundle/ui/workspaceBar/WorkspaceBarStatusItem.swift` | Its own `NSStatusItem`, fed from `updateTrayText()` after every refresh |
| `Sources/AppBundle/config/parseWorkspaceBar.swift` | `workspace-bar.*` keys |
| `Sources/AppBundle/config/editableWorkspaceSettings.swift` | Read/rewrite the count, bar options and workspace hotkeys; verified by re-parsing |
| `Sources/AppBundle/ui/settings/SettingsPane.swift` | Panes under "Settings" in the sidebar. A new pane is one enum case plus a view in its own file; it writes the config with `editor.editConfig { text in ... }` |
| `Sources/AppBundle/ui/settings/WorkspacesPane.swift` | The Workspaces pane |
| `Sources/WorkspaceBarPreview/main.swift` | Dev harness: `--snapshot out.png` renders the bar states; `--live 30` shows a demo bar in the menu bar for 30 s |

The bar is a separate status item instead of the SwiftUI `MenuBarExtra` label because that label is one button that
opens the menu, so it can't have a click target per workspace.

```sh
swift run KeybindingEditorPreview --config /tmp/scratch.toml --pane workspaces
swift run WorkspaceBarPreview --snapshot /tmp/bar.png
```

## App hotkeys: focus or launch. Built; not yet tried inside the running WM

`focus-app` jumps to an app wherever it is: it switches to the workspace of the app's most recently used window (across
all instances of the app) and focuses it; a hidden app is unhidden there. Pressing it again while macOS has the app in
front cycles through the app's windows across workspaces (one window: nothing happens). "In front" is macOS's frontmost
app, not AeroSpace's remembered focus, which stays put while an unmanaged window (like this settings window) is in front;
when the two disagree, the command brings the window forward itself. An app with all windows minimized gets the
Dock-click "reopen"; an app that isn't running is launched. Recency comes from `Window.lastNativeFocus`, bumped in
`focusCache.swift` whenever macOS focus moves to another window.

```toml
alt-b = 'focus-app --default-browser'        # the system's default browser, looked up on every press
alt-enter = 'focus-app --default-terminal'   # first installed of Tern, Ghostty, kitty, Alacritty, WezTerm, iTerm2, Warp, Terminal
alt-shift-m = 'focus-app com.apple.Music'    # a bundle id, or an app name
```

Settings → **Apps** in the keybinding editor window lists app shortcuts: app (installed apps with icons, or Default
browser / Default terminal), recorded shortcut, and an optional **home workspace**. A home workspace is a plain
`[[on-window-detected]]` rule (`if.app-id`, optional `check-further-callbacks = true`, `run = 'move-node-to-workspace N'`),
so new windows of the app open there; other rules are never shown or touched. New home rules go before all other rules
with `check-further-callbacks = true`: AeroSpace stops at the first matching rule, so appending could leave the home
unreachable behind an existing rule for the app. The home belongs to the app, not the row: two shortcuts to Chrome show
one home, and pointing a shortcut at another app leaves Chrome's home in place. Configs that write `on-window-detected`
as an inline array show homes read-only. "Suggested" offers Omarchy's launch-or-focus apps for the configured Super key
(the modifiers of the binding that runs `workspace 1`; no such binding, no suggestions); when those keys already open an
app, the suggestion focuses that app instead. While Option is Super, a row notes the character the shortcut takes away
(⌥B types ∫). Both panes share one Save. In either pane, Esc while recording a just-added shortcut takes it back.

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

- ~~Clickable workspace bar (Waybar-style 1–5 indicator).~~ Built, see Workspace bar above.
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
