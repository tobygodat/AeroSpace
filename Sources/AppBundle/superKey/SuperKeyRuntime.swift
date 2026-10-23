import AppKit
import Common
import IOKit.hidsystem

enum SuperKeyStatus: Equatable {
    /// Super is Option or Command, no binding uses it, or AeroSpace is disabled: no tap, Caps Lock untouched
    case off
    case on(SuperKey)
    /// Super couldn't start or stopped working. Caps Lock is back to normal
    case failed(String)
    /// Giving Caps Lock back failed, so it's still F18. Retried every 2 seconds. A working tap stays on meanwhile, so
    /// Caps Lock keeps working as Super
    case capsLockStuck(String)
}

/// What the runtime needs from a running Super key tap: `SuperKeyTap` in the app, a fake in tests
protocol RunningSuperKeyTap: AnyObject {
    var sources: Set<SuperSource> { get }
    var isEnabled: Bool { get }
    func reenable()
    func stop()
}

extension SuperKeyTap: RunningSuperKeyTap {}

/// Runs the Super key tap and the Caps Lock remap while they're needed, and makes sure Caps Lock is never left
/// remapped without a working tap
@MainActor
final class SuperKeyRuntime: ObservableObject {
    static let shared: SuperKeyRuntime = SuperKeyRuntime(
        remap: CapsLockRemap(
            hidutil: runHidutil,
            markerUrl: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/AeroSpace/caps-lock-remap.json"),
        ),
        startTap: { sources in
            let tap = SuperKeyTap(
                sources: sources,
                onChord: { chord in DispatchQueue.main.async { MainActor.assumeIsolated { superChordPressed(chord) } } },
                onDisabled: { DispatchQueue.main.async { MainActor.assumeIsolated { SuperKeyRuntime.shared.checkHealth() } } },
            )
            if tap.start() { return tap }
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            return nil
        },
        isTrusted: { AXIsProcessTrusted() },
        turnCapsLockOff: turnOffCapsLock,
    )

    /// Set by the runtime. The preview harness sets it to render each state
    @Published var status: SuperKeyStatus = .off

    private let remap: CapsLockRemap
    /// nil when macOS refuses the tap
    private let startTap: (Set<SuperSource>) -> (any RunningSuperKeyTap)?
    private let isTrusted: () -> Bool
    private let turnCapsLockOff: () -> Void
    private var tap: (any RunningSuperKeyTap)? = nil
    private var watchdog: Timer? = nil
    private var healthChecks = 0
    /// Only the running app manages Super. The preview harness and tests that use `shared` never call `start`, so they
    /// can't remap Caps Lock
    private var isStarted = false
    /// The keybinding editor is recording a shortcut, so Super works even before a binding uses it
    private var isRecording = false
    /// What `status` becomes once a stuck Caps Lock is given back
    private var statusAfterRestore: SuperKeyStatus = .off
    private var sigtermSource: (any DispatchSourceSignal)? = nil

    init(
        remap: CapsLockRemap,
        startTap: @escaping (Set<SuperSource>) -> (any RunningSuperKeyTap)?,
        isTrusted: @escaping () -> Bool,
        turnCapsLockOff: @escaping () -> Void,
    ) {
        self.remap = remap
        self.startTap = startTap
        self.isTrusted = isTrusted
        self.turnCapsLockOff = turnCapsLockOff
    }

    /// At launch, before AeroSpace waits for permissions or reads the config: gives Caps Lock back if the last run died
    /// with it remapped
    func start() {
        isStarted = true
        tearDown(then: .off)
    }

    /// Gives Caps Lock back when AeroSpace quits, including on SIGTERM (`killall AeroSpace`)
    func restoreCapsLockOnTermination() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        // A handler, unlike SIG_IGN, isn't inherited by the processes AeroSpace starts. The work happens off the main
        // thread, so SIGTERM still ends a hung AeroSpace
        signal(SIGTERM, { _ in })
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { [remap] in
            _ = remap.restore()
            signal(SIGTERM, SIG_DFL)
            raise(SIGTERM)
        }
        source.resume()
        sigtermSource = source
    }

    /// Starts, restarts or stops Super to match `config`. Called on every config reload, when AeroSpace is enabled or
    /// disabled, and when the keybinding editor starts or stops recording
    func sync(_ config: Config) {
        guard isStarted else { return }
        let superKey = config.superKey
        let isNeeded = isRecording || (config.usesSuperModifier && activeMode != nil)
        let sources = isNeeded ? superKey.tapSources : []
        if status == .on(superKey), let tap, tap.sources == sources, tap.isEnabled { return }
        tearDown(then: .off)
        guard status == .off, !sources.isEmpty else { return }

        if sources.contains(.capsLock) {
            if case .failure(let msg) = remap.apply() {
                fail(msg)
                return
            }
            turnCapsLockOff() // Nothing can turn it off once Caps Lock is F18
        }
        guard let tap = startTap(sources) else {
            fail("macOS blocked the Super key. Allow AeroSpace in Privacy & Security → Accessibility and Input Monitoring, then try again")
            return
        }
        self.tap = tap
        status = .on(superKey)
        startWatchdog()
    }

    func setRecording(_ isRecording: Bool, _ config: Config = config) {
        self.isRecording = isRecording
        sync(config)
    }

    /// Every 2 seconds while the tap runs or Caps Lock is stuck. The tap gets disabled when its thread stalls or a
    /// permission is revoked: re-enable it, or fail safe
    func checkHealth() {
        if case .capsLockStuck = status {
            tearDown(then: statusAfterRestore)
            return
        }
        guard let tap else { return }
        if !tap.isEnabled { tap.reenable() }
        if !isTrusted() {
            fail("AeroSpace lost Accessibility permission")
        } else if !tap.isEnabled {
            fail("macOS turned the Super key off and it couldn't be turned back on")
        } else if tap.sources.contains(.capsLock) {
            healthChecks += 1
            // Every 10 seconds: a keyboard plugged in since gets the remap too. If that fails, its Caps Lock just stays
            // Caps Lock
            if healthChecks % 5 == 0 { _ = remap.apply() }
        }
    }

    func retry() {
        sync(config)
    }

    /// Stops the tap and gives Caps Lock back, on quit. Safe to call any number of times
    func stop() {
        tearDown(then: .off)
    }

    /// Fail safe: Caps Lock goes back to what it was, and the menu says why Super is off
    private func fail(_ message: String) {
        tearDown(then: .failed(message))
    }

    /// Gives Caps Lock back and stops the tap, then `status` becomes `next`. If Caps Lock can't be given back, a working
    /// Caps Lock tap stays on so the key isn't dead, and the watchdog keeps trying
    private func tearDown(then next: SuperKeyStatus) {
        stopWatchdog()
        if case .failure(let error) = remap.restore() {
            if let tap, !(tap.sources.contains(.capsLock) && tap.isEnabled) {
                tap.stop()
                self.tap = nil
            }
            status = .capsLockStuck(error)
            statusAfterRestore = next
            startWatchdog()
            return
        }
        tap?.stop()
        tap = nil
        status = next
    }

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }
}

/// Turns the Caps Lock light and state off
private func turnOffCapsLock() {
    guard CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) else { return }
    let service = unsafe IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard unsafe IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
    defer { IOServiceClose(connect) }
    IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
}
