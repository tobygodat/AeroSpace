import CoreGraphics

let kVKF18: UInt16 = 0x4F
let kVKRightCommand: UInt16 = 0x36
let kVKEscape: UInt16 = 0x35
private let leftCmdDeviceMask: UInt64 = 0x08 // NX_DEVICELCMDKEYMASK
private let rightCmdDeviceMask: UInt64 = 0x10 // NX_DEVICERCMDKEYMASK

/// Super and a key. `modifiers` are the other modifiers held with it, without Super
struct SuperChord: Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: HotkeyModifiers
}

/// A keyboard or mouse event, as far as Super is concerned
enum SuperKeyInput: Equatable, Sendable {
    case superDown(SuperSource, isRepeat: Bool)
    case superUp(SuperSource)
    case keyDown(keyCode: UInt16, modifiers: HotkeyModifiers, isRepeat: Bool)
    case keyUp(keyCode: UInt16)
    /// Another modifier changed or a mouse button went down, so Super isn't pressed alone
    case otherInput
}

enum SuperKeyAction: Equatable, Sendable {
    case pass
    case swallow
    /// Swallow the event and run what Super and this chord are bound to, if anything
    case chord(SuperChord)
    /// Swallow the event and send Escape: Caps Lock was tapped alone
    case escape
}

/// Who holds Super. The first Super key pressed owns it until it's released. A Super key pressed meanwhile does nothing
/// (no stacking, no takeover, no Command) until it's released too. While Super is held every key press is a chord: it
/// runs its binding or does nothing, and never reaches the app
struct SuperKeyOwnership: Equatable, Sendable {
    /// Caps Lock held longer than this sends no Escape on release
    static let tapTimeoutNanos: UInt64 = 500_000_000

    struct Owner: Equatable, Sendable {
        let source: SuperSource
        let pressedAt: UInt64
        var isAlone: Bool
    }

    private(set) var owner: Owner? = nil
    private(set) var inert: Set<SuperSource> = []
    /// Keys whose press was a chord. Their repeats and release are swallowed too, even after Super is released
    private(set) var swallowedKeys: Set<UInt16> = []

    var heldSources: Set<SuperSource> { owner.map { inert.union([$0.source]) } ?? inert }

    /// `now` is a monotonic clock in nanoseconds
    mutating func handle(_ input: SuperKeyInput, at now: UInt64) -> SuperKeyAction {
        switch input {
            case .superDown(let source, let isRepeat):
                if heldSources.contains(source) || isRepeat { return .swallow }
                if owner == nil {
                    owner = Owner(source: source, pressedAt: now, isAlone: true)
                } else {
                    owner?.isAlone = false
                    inert.insert(source)
                }
                return .swallow
            case .superUp(let source):
                if let owner, owner.source == source {
                    self.owner = nil
                    let isTap = source == .capsLock && owner.isAlone && now >= owner.pressedAt && now - owner.pressedAt <= Self.tapTimeoutNanos
                    return isTap ? .escape : .swallow
                }
                return inert.remove(source) != nil ? .swallow : .pass
            case .keyDown(let keyCode, let modifiers, let isRepeat):
                if isRepeat { return swallowedKeys.contains(keyCode) ? .swallow : .pass }
                swallowedKeys.remove(keyCode)
                guard owner != nil else { return .pass }
                owner?.isAlone = false
                swallowedKeys.insert(keyCode)
                return .chord(SuperChord(keyCode: keyCode, modifiers: modifiers))
            case .keyUp(let keyCode):
                return swallowedKeys.remove(keyCode) != nil ? .swallow : .pass
            case .otherInput:
                owner?.isAlone = false
                return .pass
        }
    }
}

/// What a tapped event means for Super, given the keys that are Super. nil: the event doesn't concern Super
func superKeyInput(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool, sources: Set<SuperSource>) -> SuperKeyInput? {
    switch type {
        case .keyDown, .keyUp:
            let isDown = type == .keyDown
            if keyCode == kVKF18 && sources.contains(.capsLock) { // Caps Lock, remapped by hidutil
                return isDown ? .superDown(.capsLock, isRepeat: isRepeat) : .superUp(.capsLock)
            }
            return isDown ? .keyDown(keyCode: keyCode, modifiers: chordModifiers(flags, sources), isRepeat: isRepeat) : .keyUp(keyCode: keyCode)
        case .flagsChanged:
            if keyCode == kVKRightCommand && sources.contains(.rightCmd) {
                return flags.rawValue & rightCmdDeviceMask != 0 ? .superDown(.rightCmd, isRepeat: false) : .superUp(.rightCmd)
            }
            return .otherInput
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .otherInput
        default:
            return nil
    }
}

/// Shift, Control, Option and Command of a key press. Right Command isn't Command while it's a Super key
func chordModifiers(_ flags: CGEventFlags, _ sources: Set<SuperSource>) -> HotkeyModifiers {
    var result: HotkeyModifiers = []
    if flags.contains(.maskShift) { result.insert(.shift) }
    if flags.contains(.maskControl) { result.insert(.control) }
    if flags.contains(.maskAlternate) { result.insert(.option) }
    if flags.contains(.maskCommand) && (!sources.contains(.rightCmd) || isLeftCommandHeld(flags)) { result.insert(.command) }
    return result
}

/// The flags an event passes on with while Right Command is held as a Super key: it doesn't count as Command
func flagsWithoutSuper(_ flags: CGEventFlags, held: Set<SuperSource>) -> CGEventFlags {
    guard held.contains(.rightCmd) else { return flags }
    var raw = flags.rawValue & ~rightCmdDeviceMask
    if !isLeftCommandHeld(flags) { raw &= ~CGEventFlags.maskCommand.rawValue }
    return CGEventFlags(rawValue: raw)
}

/// Events without device-dependent bits (posted by other apps) count as left Command
private func isLeftCommandHeld(_ flags: CGEventFlags) -> Bool {
    flags.rawValue & leftCmdDeviceMask != 0 || flags.rawValue & (leftCmdDeviceMask | rightCmdDeviceMask) == 0
}
