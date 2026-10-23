import Common

/// Which physical key is Super: `super-key` in the config. `super-*` bindings use it
enum SuperKey: String, CaseIterable, Sendable {
    /// Held is Super, tapped alone is Escape. Remapped to F18 with hidutil while a binding uses Super
    case capsLock = "caps-lock"
    /// Left Command stays Command
    case rightCmd = "right-cmd"
    /// The first of the two pressed is Super until it's released. The other one does nothing meanwhile
    case capsLockOrRightCmd = "caps-lock-or-right-cmd"
    case alt
    case cmd

    /// The keys the Super key tap watches. Empty when Super is Option or Command, which plain Carbon hotkeys handle
    var tapSources: Set<SuperSource> {
        switch self {
            case .capsLock: [.capsLock]
            case .rightCmd: [.rightCmd]
            case .capsLockOrRightCmd: [.capsLock, .rightCmd]
            case .alt, .cmd: []
        }
    }

    /// The real modifier Super is, when it is one
    var standsFor: HotkeyModifiers? {
        switch self {
            case .alt: .option
            case .cmd: .command
            case .capsLock, .rightCmd, .capsLockOrRightCmd: nil
        }
    }
}

/// A physical key the Super key tap can treat as Super
enum SuperSource: Hashable, Sendable {
    case capsLock
    case rightCmd
}

func parseSuperKey(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<SuperKey> {
    parseString(raw, backtrace).flatMap { value in
        SuperKey(rawValue: value).toResult(.init(
            backtrace,
            "Can't parse super-key '\(value)'. Possible values: \(SuperKey.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", "))",
        ))
    }
}

extension Config {
    /// Whether any mode has a `super-*` binding. The Super key tap and the Caps Lock remap only run when one does
    var usesSuperModifier: Bool {
        modes.values.contains { mode in mode.bindings.values.contains { $0.modifiers.contains(.superKey) } }
    }
}
