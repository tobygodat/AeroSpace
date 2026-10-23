import CoreGraphics
import Foundation

private let syntheticEventMarker: Int64 = 0x5375_7065 // "Supe": the Escape this tap posts, which it lets through

/// The event tap behind Super on Caps Lock and Right Command. It runs on a thread of its own, so a busy main thread
/// never holds up typing. `SuperKeyOwnership` decides what happens to each event.
/// `ownership` is only touched on the tap thread. `port` and `runLoop` are written once, before the tap is enabled
final class SuperKeyTap: @unchecked Sendable {
    let sources: Set<SuperSource>
    private let onChord: @Sendable (SuperChord) -> Void
    private let onDisabled: @Sendable () -> Void
    private var ownership = SuperKeyOwnership()
    private var port: CFMachPort? = nil
    private var runLoop: CFRunLoop? = nil

    init(sources: Set<SuperSource>, onChord: @escaping @Sendable (SuperChord) -> Void, onDisabled: @escaping @Sendable () -> Void) {
        self.sources = sources
        self.onChord = onChord
        self.onDisabled = onDisabled
    }

    /// false when macOS refuses the tap, which means AeroSpace lacks Accessibility (or Input Monitoring) permission
    func start() -> Bool {
        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if sources.contains(.rightCmd) { // Right Command stays down while it's Super, so these would carry Command to apps
            types += [.leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        }
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let port = unsafe CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: superKeyTapCallback,
            userInfo: unsafe Unmanaged.passUnretained(self).toOpaque(),
        ) else { return false }
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in // Keeps the tap alive until its run loop stops
            let source = CFMachPortCreateRunLoopSource(nil, self.port, 0)
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "AeroSpace Super key"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    var isEnabled: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            ownership = SuperKeyOwnership() // Events were missed
            reenable()
            if !isEnabled { onDisabled() }
            return unsafe Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            return unsafe Unmanaged.passUnretained(event)
        }
        guard let input = superKeyInput(
            type: type,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            sources: sources,
        ) else { return unsafe Unmanaged.passUnretained(event) }
        if case .keyDown = input, !ownership.heldSources.isEmpty {
            var down: Set<SuperSource> = []
            if CGEventSource.keyState(.hidSystemState, key: kVKF18) { down.insert(.capsLock) }
            if event.flags.rawValue & rightCmdDeviceMask != 0 { down.insert(.rightCmd) }
            ownership.forgetReleased(stillDown: down)
        }
        switch ownership.handle(input, at: DispatchTime.now().uptimeNanoseconds) {
            case .pass:
                event.flags = flagsWithoutSuper(event.flags, held: ownership.heldSources)
                return unsafe Unmanaged.passUnretained(event)
            case .swallow:
                return nil
            case .chord(let chord):
                onChord(chord)
                return nil
            case .escape:
                let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
                postEscape(flags: flagsWithoutSuper(event.flags, held: ownership.heldSources).intersection(modifiers))
                return nil
        }
    }

    private func postEscape(flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let escape = CGEvent(keyboardEventSource: source, virtualKey: kVKEscape, keyDown: isDown) else { continue }
            escape.flags = flags
            escape.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            escape.post(tap: .cghidEventTap)
        }
    }
}

private func superKeyTapCallback(
    _: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
    guard let userInfo = unsafe userInfo else { return unsafe Unmanaged.passUnretained(event) }
    return unsafe Unmanaged<SuperKeyTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
