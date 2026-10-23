@testable import AppBundle
import CoreGraphics
import Testing

private let ms: UInt64 = 1_000_000
private let keyB: UInt16 = 11
private let keyL: UInt16 = 37

/// Feeds events in order, 10 ms apart unless given, and collects what the machine answers
private struct Driver {
    var machine = SuperKeyOwnership()
    var now: UInt64 = 1_000 * ms

    mutating func callAsFunction(_ input: SuperKeyInput, after delay: UInt64 = 10 * ms) -> SuperKeyAction {
        now += delay
        return machine.handle(input, at: now)
    }

    mutating func press(_ keyCode: UInt16, _ modifiers: HotkeyModifiers = []) -> SuperKeyAction {
        self(.keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: false))
    }
}

private func down(_ source: SuperSource) -> SuperKeyInput { .superDown(source, isRepeat: false) }
private func up(_ source: SuperSource) -> SuperKeyInput { .superUp(source) }

// MARK: Both keys, every order

/// One press and one release of each Super key, in one of the six orders they can happen in
struct SuperKeyOrder: CustomTestStringConvertible, Sendable {
    let events: [SuperKeyInput]
    /// Who owns Super after each event
    let ownerAfter: [SuperSource?]
    let testDescription: String
}

private let a = SuperSource.capsLock
private let b = SuperSource.rightCmd

private let allOrders: [SuperKeyOrder] = [
    SuperKeyOrder(events: [down(a), up(a), down(b), up(b)], ownerAfter: [a, nil, b, nil], testDescription: "⇪↓ ⇪↑ ⌘↓ ⌘↑"),
    SuperKeyOrder(events: [down(a), down(b), up(a), up(b)], ownerAfter: [a, a, nil, nil], testDescription: "⇪↓ ⌘↓ ⇪↑ ⌘↑"),
    SuperKeyOrder(events: [down(a), down(b), up(b), up(a)], ownerAfter: [a, a, a, nil], testDescription: "⇪↓ ⌘↓ ⌘↑ ⇪↑"),
    SuperKeyOrder(events: [down(b), down(a), up(a), up(b)], ownerAfter: [b, b, b, nil], testDescription: "⌘↓ ⇪↓ ⇪↑ ⌘↑"),
    SuperKeyOrder(events: [down(b), down(a), up(b), up(a)], ownerAfter: [b, b, nil, nil], testDescription: "⌘↓ ⇪↓ ⌘↑ ⇪↑"),
    SuperKeyOrder(events: [down(b), up(b), down(a), up(a)], ownerAfter: [b, nil, a, nil], testDescription: "⌘↓ ⌘↑ ⇪↓ ⇪↑"),
]

@Suite struct SuperKeyBothKeysTest {
    @Test(arguments: allOrders)
    func firstKeyOwnsSuperUntilReleased(_ order: SuperKeyOrder) {
        var drive = Driver()
        for (event, expectedOwner) in zip(order.events, order.ownerAfter) {
            let action = drive(event)
            #expect(drive.machine.owner?.source == expectedOwner, "after \(event)")
            // Every Super key event is swallowed; only a lone Caps Lock tap turns into Escape
            #expect(action == .swallow || action == .escape, "\(event) reached the app")
        }
        #expect(drive.machine.heldSources.isEmpty)
        #expect(drive.machine == SuperKeyOwnership(), "back to idle")
    }

    /// A key pressed at any point is a Super chord exactly while a Super key owns Super. A Super key held without owning
    /// (pressed while the other owned it) adds nothing: no stacking, no takeover, no Command
    @Test(arguments: allOrders, 0 ... 4)
    func keyPressBetweenEvents(_ order: SuperKeyOrder, _ position: Int) {
        var drive = Driver()
        for event in order.events.prefix(position) { _ = drive(event) }
        let owner = position == 0 ? nil : order.ownerAfter[position - 1]
        let action = drive.press(keyB, [.shift])
        if owner != nil {
            #expect(action == .chord(SuperChord(keyCode: keyB, modifiers: [.shift])))
        } else {
            #expect(action == .pass)
        }
        #expect(drive(.keyUp(keyCode: keyB)) == (owner != nil ? .swallow : .pass))
        for event in order.events.dropFirst(position) { _ = drive(event) }
        #expect(drive.machine.owner == nil && drive.machine.inert.isEmpty)
    }

    @Test(arguments: allOrders)
    func eitherKeyClaimsSuperAgainAfterRelease(_ order: SuperKeyOrder) {
        var drive = Driver()
        for event in order.events { _ = drive(event) }
        _ = drive(down(b))
        #expect(drive.machine.owner?.source == b)
        _ = drive(up(b))
        _ = drive(down(a))
        #expect(drive.machine.owner?.source == a)
    }

    @Test func escapeOnlyForALoneCapsLockTapInEveryOrder() {
        let escapes = allOrders.map { order -> [SuperKeyAction] in
            var drive = Driver()
            return order.events.map { drive($0) }.filter { $0 == .escape }
        }
        // Caps Lock is alone only when the two keys don't overlap
        #expect(escapes.map(\.count) == [1, 0, 0, 0, 0, 1])
    }

    @Test func inertKeyStaysInertUntilItsOwnRelease() {
        var drive = Driver()
        _ = drive(down(a))
        _ = drive(down(b)) // inert
        _ = drive(up(a))
        #expect(drive.machine.owner == nil)
        #expect(drive.machine.heldSources == [b])
        #expect(drive.press(keyB) == .pass) // Right Command held inert is not Super
        _ = drive(.keyUp(keyCode: keyB))
        #expect(drive(.superDown(b, isRepeat: false)) == .swallow) // A second press event of the held key claims nothing
        #expect(drive.machine.owner == nil)
        _ = drive(up(b))
        _ = drive(down(b))
        #expect(drive.machine.owner?.source == b)
    }
}

// MARK: Caps Lock tap and hold

@Suite struct SuperKeyTapAndHoldTest {
    @Test func quickTapIsEscape() {
        var drive = Driver()
        #expect(drive(down(a)) == .swallow)
        #expect(drive(up(a), after: 120 * ms) == .escape)
    }

    @Test func holdPastTheTimeoutIsNotEscape() {
        var drive = Driver()
        _ = drive(down(a))
        #expect(drive(up(a), after: SuperKeyOwnership.tapTimeoutNanos + ms) == .swallow)
    }

    @Test func tapAtExactlyTheTimeoutIsEscape() {
        var drive = Driver()
        _ = drive(down(a))
        #expect(drive(up(a), after: SuperKeyOwnership.tapTimeoutNanos) == .escape)
    }

    @Test func chordCancelsEscape() {
        var drive = Driver()
        _ = drive(down(a))
        #expect(drive.press(keyB) == .chord(SuperChord(keyCode: keyB, modifiers: [])))
        _ = drive(.keyUp(keyCode: keyB))
        #expect(drive(up(a)) == .swallow)
    }

    /// Super pressed with only another modifier (Shift, say) and released: nothing happens
    @Test func modifierOnlyPressIsNotEscape() {
        var drive = Driver()
        _ = drive(down(a))
        #expect(drive(.otherInput) == .pass)
        #expect(drive(up(a)) == .swallow)
    }

    @Test func mouseClickWhileHeldIsNotEscape() {
        var drive = Driver()
        _ = drive(down(a))
        _ = drive(.otherInput)
        #expect(drive(up(a)) == .swallow)
    }

    @Test func rightCommandTapSendsNothing() {
        var drive = Driver()
        #expect(drive(down(b)) == .swallow)
        #expect(drive(up(b), after: 50 * ms) == .swallow)
    }

    @Test func autorepeatOfCapsLockKeepsTheTapAlive() {
        var drive = Driver()
        _ = drive(down(a))
        for _ in 0 ..< 3 { #expect(drive(.superDown(a, isRepeat: true), after: 30 * ms) == .swallow) }
        #expect(drive.machine.owner?.isAlone == true)
        #expect(drive(up(a)) == .escape)
    }

    @Test func modifierHeldBeforeSuperStillAllowsEscape() {
        var drive = Driver()
        _ = drive(.otherInput) // Shift goes down first
        _ = drive(down(a))
        #expect(drive(up(a)) == .escape)
    }
}

// MARK: Chords and repeats

@Suite struct SuperKeyChordTest {
    @Test func chordRepeatsAndReleaseAreSwallowed() {
        var drive = Driver()
        _ = drive(down(a))
        #expect(drive.press(keyL) == .chord(SuperChord(keyCode: keyL, modifiers: [])))
        for _ in 0 ..< 3 { #expect(drive(.keyDown(keyCode: keyL, modifiers: [], isRepeat: true)) == .swallow) }
        #expect(drive(.keyUp(keyCode: keyL)) == .swallow)
    }

    @Test func chordKeyReleasedAfterSuperIsStillSwallowed() {
        var drive = Driver()
        _ = drive(down(a))
        _ = drive.press(keyL)
        _ = drive(up(a))
        #expect(drive(.keyDown(keyCode: keyL, modifiers: [], isRepeat: true)) == .swallow)
        #expect(drive(.keyUp(keyCode: keyL)) == .swallow)
        #expect(drive.press(keyL) == .pass)
    }

    @Test func keyHeldBeforeSuperKeepsRepeatingToTheApp() {
        var drive = Driver()
        #expect(drive.press(keyL) == .pass)
        _ = drive(down(a))
        #expect(drive(.keyDown(keyCode: keyL, modifiers: [], isRepeat: true)) == .pass)
        #expect(drive(.keyUp(keyCode: keyL)) == .pass)
        #expect(drive.machine.owner?.isAlone == true)
    }

    @Test func missedReleaseDoesNotSwallowTheNextPress() {
        var drive = Driver()
        _ = drive(down(a))
        _ = drive.press(keyL) // Its release never arrives
        _ = drive(up(a))
        #expect(drive.press(keyL) == .pass)
        #expect(drive(.keyUp(keyCode: keyL)) == .pass)
    }

    @Test func otherModifiersRideAlong() {
        var drive = Driver()
        _ = drive(down(b))
        #expect(drive.press(keyB, [.control, .shift]) == .chord(SuperChord(keyCode: keyB, modifiers: [.control, .shift])))
    }

    @Test func strayReleaseOfASuperKeyPasses() {
        var drive = Driver()
        #expect(drive(up(b)) == .pass) // Pressed before the tap started
        #expect(drive.machine == SuperKeyOwnership())
    }
}

// MARK: Decoding tapped events

@Suite struct SuperKeyInputTest {
    private let rightCmdDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    private let leftCmdDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
    private let bothCmdDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x18)

    @Test func f18IsCapsLockOnlyWhileCapsLockIsSuper() {
        #expect(superKeyInput(type: .keyDown, keyCode: kVKF18, flags: [], isRepeat: false, sources: [.capsLock]) == .superDown(.capsLock, isRepeat: false))
        #expect(superKeyInput(type: .keyDown, keyCode: kVKF18, flags: [], isRepeat: true, sources: [.capsLock, .rightCmd]) == .superDown(.capsLock, isRepeat: true))
        #expect(superKeyInput(type: .keyUp, keyCode: kVKF18, flags: [], isRepeat: false, sources: [.capsLock]) == .superUp(.capsLock))
        #expect(superKeyInput(type: .keyDown, keyCode: kVKF18, flags: [], isRepeat: false, sources: [.rightCmd]) == .keyDown(keyCode: kVKF18, modifiers: [], isRepeat: false))
    }

    @Test func rightCommandPressAndReleaseFromDeviceFlags() {
        #expect(superKeyInput(type: .flagsChanged, keyCode: kVKRightCommand, flags: rightCmdDown, isRepeat: false, sources: [.rightCmd]) == .superDown(.rightCmd, isRepeat: false))
        #expect(superKeyInput(type: .flagsChanged, keyCode: kVKRightCommand, flags: bothCmdDown, isRepeat: false, sources: [.rightCmd]) == .superDown(.rightCmd, isRepeat: false))
        #expect(superKeyInput(type: .flagsChanged, keyCode: kVKRightCommand, flags: leftCmdDown, isRepeat: false, sources: [.rightCmd]) == .superUp(.rightCmd))
        #expect(superKeyInput(type: .flagsChanged, keyCode: kVKRightCommand, flags: [], isRepeat: false, sources: [.rightCmd]) == .superUp(.rightCmd))
        #expect(superKeyInput(type: .flagsChanged, keyCode: kVKRightCommand, flags: rightCmdDown, isRepeat: false, sources: [.capsLock]) == .otherInput)
        #expect(superKeyInput(type: .flagsChanged, keyCode: 0x37, flags: leftCmdDown, isRepeat: false, sources: [.rightCmd]) == .otherInput)
    }

    @Test func rightCommandIsNotCommandInAChordWhileItIsSuper() {
        #expect(chordModifiers(rightCmdDown, [.rightCmd]) == [])
        #expect(chordModifiers(bothCmdDown, [.rightCmd]) == [.command])
        #expect(chordModifiers(rightCmdDown, [.capsLock]) == [.command])
        #expect(chordModifiers(.maskCommand, [.rightCmd]) == [.command]) // Posted events carry no device bits
        #expect(chordModifiers([.maskShift, .maskControl, .maskAlternate], [.capsLock]) == [.shift, .control, .option])
    }

    @Test func mouseDownsBreakAloneAndOtherEventsAreIgnored() {
        #expect(superKeyInput(type: .leftMouseDown, keyCode: 0, flags: [], isRepeat: false, sources: [.capsLock]) == .otherInput)
        #expect(superKeyInput(type: .otherMouseDown, keyCode: 0, flags: [], isRepeat: false, sources: [.capsLock]) == .otherInput)
        #expect(superKeyInput(type: .mouseMoved, keyCode: 0, flags: [], isRepeat: false, sources: [.capsLock]) == nil)
    }

    @Test func passedEventsLoseRightCommandWhileItIsHeldAsSuper() {
        #expect(flagsWithoutSuper(rightCmdDown, held: [.rightCmd]) == [])
        #expect(flagsWithoutSuper(bothCmdDown, held: [.rightCmd]) == leftCmdDown)
        #expect(flagsWithoutSuper(rightCmdDown, held: [.capsLock]) == rightCmdDown)
        #expect(flagsWithoutSuper(CGEventFlags(rawValue: rightCmdDown.rawValue | CGEventFlags.maskShift.rawValue), held: [.rightCmd]) == .maskShift)
    }
}
