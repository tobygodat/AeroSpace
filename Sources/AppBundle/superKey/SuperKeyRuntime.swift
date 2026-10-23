import AppKit
import Common

enum SuperKeyStatus: Equatable {
    /// Super is Option or Command, or no binding uses it: no tap, Caps Lock untouched
    case off
    case on(SuperKey)
    /// Super couldn't start or stopped working. Caps Lock is back to normal
    case failed(String)
}

/// Runs the Super key tap and the Caps Lock remap while the config needs them, and makes sure Caps Lock is never left
/// remapped without a working tap
@MainActor
final class SuperKeyRuntime: ObservableObject {
    static let shared = SuperKeyRuntime(remap: CapsLockRemap(
        hidutil: runHidutil,
        markerUrl: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AeroSpace/caps-lock-remap.json"),
    ))

    /// Set by the runtime. The preview harness sets it to render each state
    @Published var status: SuperKeyStatus = .off

    private let remap: CapsLockRemap
    private var tap: SuperKeyTap? = nil
    private var watchdog: Timer? = nil
    private var isFirstSync = true

    init(remap: CapsLockRemap) {
        self.remap = remap
    }

    /// Starts, restarts or stops Super for `config`. Called on every config reload
    func sync(_ config: Config) {
        if isFirstSync {
            isFirstSync = false
            _ = remap.restore() // A previous run crashed with Caps Lock remapped
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SuperKeyRuntime.shared.stop() }
            }
        }
        let superKey = config.superKey
        let sources = config.usesSuperModifier ? superKey.tapSources : []
        if status == .on(superKey), tap?.sources == sources, tap?.isEnabled == true { return }
        if let error = tearDown() {
            status = .failed(error)
            return
        }
        status = .off
        if sources.isEmpty { return }

        if sources.contains(.capsLock), case .failure(let msg) = remap.apply() {
            fail(msg)
            return
        }
        let tap = SuperKeyTap(
            sources: sources,
            onChord: { chord in DispatchQueue.main.async { MainActor.assumeIsolated { superChordPressed(chord) } } },
            onDisabled: { DispatchQueue.main.async { MainActor.assumeIsolated { SuperKeyRuntime.shared.checkHealth() } } },
        )
        guard tap.start() else {
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            fail("macOS blocked the Super key. Allow AeroSpace in Privacy & Security → Accessibility and Input Monitoring, then try again")
            return
        }
        self.tap = tap
        status = .on(superKey)
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SuperKeyRuntime.shared.checkHealth() }
        }
    }

    /// The tap gets disabled when its thread stalls or a permission is revoked. Re-enable it, or fail safe
    func checkHealth() {
        guard let tap else { return }
        if !tap.isEnabled { tap.reenable() }
        if !AXIsProcessTrusted() {
            fail("AeroSpace lost Accessibility permission")
        } else if !tap.isEnabled {
            fail("macOS turned the Super key off and it couldn't be turned back on")
        }
    }

    func retry() {
        sync(config)
    }

    /// Stops the tap and gives Caps Lock back, on quit. Safe to call any number of times
    func stop() {
        _ = tearDown()
    }

    /// Fail safe: Caps Lock goes back to what it was, and the menu says why Super is off
    private func fail(_ message: String) {
        status = .failed([message, tearDown()].compactMap { $0 }.joined(separator: ". "))
    }

    /// nil, or why Caps Lock couldn't be given back
    private func tearDown() -> String? {
        watchdog?.invalidate()
        watchdog = nil
        tap?.stop()
        tap = nil
        return remap.restore().failureOrNil
    }
}
