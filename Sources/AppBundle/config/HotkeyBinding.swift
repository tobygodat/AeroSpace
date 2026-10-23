import AppKit
import Common
import Foundation
import HotKey

@MainActor private var hotkeys: [String: HotKey] = [:]

@MainActor func resetHotKeys() {
    // Explicitly unregister all hotkeys. We cannot always rely on destruction of the HotKey object to trigger
    // unregistration because we might be running inside a hotkey handler that is keeping its HotKey object alive.
    for (_, key) in hotkeys {
        key.isEnabled = false
    }
    hotkeys = [:]
}

/// Temporarily lets all keystrokes through to the focused app, e.g. while the keybinding editor records a shortcut
@MainActor func setHotKeysPaused(_ paused: Bool) {
    let activeBindings = activeMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    for (binding, key) in hotkeys {
        key.isEnabled = !paused && activeBindings.keys.contains(binding)
    }
}

extension HotKey {
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}

@MainActor var activeMode: String? = mainModeId
@MainActor func activateMode_nonCancellable(_ targetMode: String?) async {
    let targetBindings = targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    for binding in targetBindings.values where !hotkeys.keys.contains(binding.descriptionWithKeyCode) {
        // Super on Caps Lock or Right Command goes through the Super key tap instead (superChordPressed)
        guard let modifiers = binding.modifiers.carbonFlags(config.superKey) else { continue }
        hotkeys[binding.descriptionWithKeyCode] = HotKey(key: binding.keyCode, modifiers: modifiers, keyDownHandler: {
            runHotkeyBinding(binding)
        })
    }
    for (binding, key) in hotkeys {
        key.isEnabled = targetBindings.keys.contains(binding)
    }
    let oldMode = activeMode
    activeMode = targetMode
    if (oldMode == nil) != (targetMode == nil) { SuperKeyRuntime.shared.sync(config) } // AeroSpace was enabled or disabled
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        _ = await config.onModeChanged.run(.defaultEnv, .emptyStdin)
    }
}

@MainActor private func runHotkeyBinding(_ binding: HotkeyBinding) {
    Task.startUnstructured {
        if let activeMode {
            broadcastEvent(.bindingTriggered(
                mode: activeMode,
                binding: binding.descriptionWithKeyNotation,
            ))
            try await runLightSession(.hotkeyBinding, .checkServerIsEnabledOrDie()) { () throws in
                _ = await config.modes[activeMode]?.bindings[binding.descriptionWithKeyCode]?.commands
                    .run(.defaultEnv, .emptyStdin)
            }
        }
    }
}

/// While the keybinding editor records a shortcut, Super chords go to it instead of running bindings
@MainActor var superChordRecorder: ((SuperChord) -> Void)? = nil

/// Super (Caps Lock or Right Command) + a key, reported by the Super key tap
@MainActor func superChordPressed(_ chord: SuperChord) {
    if let superChordRecorder {
        superChordRecorder(chord)
        return
    }
    let modifiers = chord.modifiers.union(.superKey)
    guard let activeMode,
          let binding = config.modes[activeMode]?.bindings.values
          .first(where: { $0.modifiers == modifiers && $0.keyCode.carbonKeyCode == UInt32(chord.keyCode) })
    else { return }
    runHotkeyBinding(binding)
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: HotkeyModifiers
    let keyCode: Key
    let commands: Shell<any Command>
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    init(_ modifiers: HotkeyModifiers, _ keyCode: Key, _ commands: Shell<any Command>, descriptionWithKeyNotation: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.commands.strictEquals(rhs.commands)
    }
}

func parseBindings(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext, _ mapping: [String: Key], _ superKey: SuperKey) -> [String: HotkeyBinding] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: HotkeyBinding] = [:]
    var writtenWithSuper: Set<String> = []
    for (binding, rawCommand): (String, OrderedJson) in rawTable {
        let backtrace = backtrace + .key(binding)
        let parsed = parseBinding(binding, backtrace, mapping)
            .map { modifiers, key -> (binding: HotkeyBinding, usesSuper: Bool) in
                let commands = parseShellOfCommandsForConfig(rawCommand, backtrace, &c)
                // While Super is Option or Command, 'super-b' is that binding: one hotkey, also across modes
                return (HotkeyBinding(modifiers.resolvingSuper(superKey), key, commands, descriptionWithKeyNotation: binding), modifiers.contains(.superKey))
            }
            .getOrNil(appendErrorTo: &c.errors)
        if let (binding, usesSuper) = parsed {
            if let other = result[binding.descriptionWithKeyCode] {
                c.errors.append(.init(backtrace, usesSuper != writtenWithSuper.contains(binding.descriptionWithKeyCode)
                    ? "'\(binding.descriptionWithKeyNotation)' and '\(other.descriptionWithKeyNotation)' are the same keys while super-key = '\(superKey.rawValue)'"
                    : "'\(binding.descriptionWithKeyCode)' Binding redeclaration"))
            }
            result[binding.descriptionWithKeyCode] = binding
            if usesSuper { writtenWithSuper.insert(binding.descriptionWithKeyCode) } else { writtenWithSuper.remove(binding.descriptionWithKeyCode) }
        }
    }
    return result
}

func parseBinding(_ raw: String, _ backtrace: ConfigBacktrace, _ mapping: [String: Key]) -> ResOrConfigParseDiagnostic<(HotkeyModifiers, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ResOrConfigParseDiagnostic<HotkeyModifiers> = rawKeys.dropLast()
        .mapAllOrFailure {
            modifiersMap[String($0)].toResult(.init(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { HotkeyModifiers($0) }
    let key: ResOrConfigParseDiagnostic<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .toResult(.init(backtrace, "Can't parse the key in '\(raw)' binding"))
    return modifiers.flatMap { modifiers -> ResOrConfigParseDiagnostic<(HotkeyModifiers, Key)> in
        key.flatMap { key -> ResOrConfigParseDiagnostic<(HotkeyModifiers, Key)> in
            .success((modifiers, key))
        }
    }
}
