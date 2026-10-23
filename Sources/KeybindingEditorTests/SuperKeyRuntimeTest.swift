@testable import AppBundle
import Foundation
import Testing

/// A tap that only remembers what the runtime did with it
private final class FakeTap: RunningSuperKeyTap {
    let sources: Set<SuperSource>
    var isEnabled = true
    var canReenable = true
    var isStopped = false

    init(_ sources: Set<SuperSource>) { self.sources = sources }

    func reenable() { if canReenable { isEnabled = true } }

    func stop() {
        isStopped = true
        isEnabled = false
    }
}

/// The runtime with fake keyboards, a fake tap and a fake permission. Nothing touches the real HID system
@MainActor
private final class Rig {
    let hid = FakeHidutil([[]])
    let markerUrl = FileManager.default.temporaryDirectory.appending(path: "super-key-runtime-\(UUID().uuidString).json")
    var taps: [FakeTap] = []
    var refuseTap = false
    var isTrusted = true
    var capsLockTurnedOff = 0
    private(set) var runtime: SuperKeyRuntime! = nil

    var remap: CapsLockRemap { CapsLockRemap(hidutil: { [hid] in try hid.run($0) }, markerUrl: markerUrl) }
    var tap: FakeTap? { taps.last }

    init() {
        runtime = SuperKeyRuntime(
            remap: remap,
            startTap: { [unowned self] sources in
                if refuseTap { return nil }
                taps.append(FakeTap(sources))
                return taps.last
            },
            isTrusted: { [unowned self] in isTrusted },
            turnCapsLockOff: { [unowned self] in capsLockTurnedOff += 1 },
        )
        runtime.start()
    }

    deinit { try? FileManager.default.removeItem(at: markerUrl) }
}

@MainActor private func config(_ toml: String) -> Config { parseConfig("config-version = 2\n" + toml).config }

private let superBindings = "[mode.main.binding]\nsuper-b = 'workspace 1'"
private let optionBindings = "[mode.main.binding]\nalt-b = 'workspace 1'"

@MainActor @Suite struct SuperKeyRuntimeTest {
    @Test func nothingStartsUntilABindingUsesSuper() {
        let rig = Rig()
        rig.runtime.sync(config(optionBindings))
        #expect(rig.runtime.status == .off)
        #expect(rig.taps.isEmpty)
        #expect(rig.hid.sets == 0)
    }

    @Test func capsLockStartsAndStops() {
        let rig = Rig()
        rig.runtime.sync(config(superBindings))
        #expect(rig.runtime.status == .on(.capsLock))
        #expect(rig.hid.keyboards == [[capsToF18]])
        #expect(rig.tap?.sources == [.capsLock])
        #expect(rig.capsLockTurnedOff == 1)

        rig.runtime.sync(config(optionBindings))
        #expect(rig.runtime.status == .off)
        #expect(rig.tap?.isStopped == true)
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func rightCommandLeavesCapsLockAlone() {
        let rig = Rig()
        rig.runtime.sync(config("super-key = 'right-cmd'\n" + superBindings))
        #expect(rig.runtime.status == .on(.rightCmd))
        #expect(rig.hid.sets == 0)
    }

    @Test func changingTheKeyRestartsTheTap() {
        let rig = Rig()
        rig.runtime.sync(config(superBindings))
        rig.runtime.sync(config("super-key = 'right-cmd'\n" + superBindings))
        #expect(rig.taps.count == 2)
        #expect(rig.taps.first?.isStopped == true)
        #expect(rig.tap?.sources == [.rightCmd])
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func aRefusedTapGivesCapsLockBack() {
        let rig = Rig()
        rig.refuseTap = true
        rig.runtime.sync(config(superBindings))
        guard case .failed = rig.runtime.status else {
            Issue.record("expected failed, got \(rig.runtime.status)")
            return
        }
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func aFailedRemapStartsNoTap() {
        let rig = Rig()
        rig.hid.failSet = true
        rig.runtime.sync(config(superBindings))
        guard case .failed = rig.runtime.status else {
            Issue.record("expected failed, got \(rig.runtime.status)")
            return
        }
        #expect(rig.taps.isEmpty)
    }

    @Test func lostPermissionFailsSafe() {
        let rig = Rig()
        rig.runtime.sync(config(superBindings))
        rig.isTrusted = false
        rig.runtime.checkHealth()
        #expect(rig.runtime.status == .failed("AeroSpace lost Accessibility permission"))
        #expect(rig.tap?.isStopped == true)
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func aDisabledTapIsTurnedBackOn() {
        let rig = Rig()
        rig.runtime.sync(config(superBindings))
        rig.tap?.isEnabled = false
        rig.runtime.checkHealth()
        #expect(rig.runtime.status == .on(.capsLock))
        #expect(rig.tap?.isEnabled == true)

        rig.tap?.isEnabled = false
        rig.tap?.canReenable = false
        rig.runtime.checkHealth()
        #expect(rig.runtime.status == .failed("macOS turned the Super key off and it couldn't be turned back on"))
        #expect(rig.hid.keyboards == [[]])
    }

    /// Never F18 with nothing behind it: while Caps Lock can't be given back, a working tap stays on
    @Test func aFailedRestoreKeepsAWorkingTapAndRetries() {
        let rig = Rig()
        rig.runtime.sync(config(superBindings))
        rig.hid.failGet = true
        rig.runtime.sync(config(optionBindings))
        guard case .capsLockStuck = rig.runtime.status else {
            Issue.record("expected capsLockStuck, got \(rig.runtime.status)")
            return
        }
        #expect(rig.tap?.isStopped == false)
        #expect(rig.hid.keyboards == [[capsToF18]])

        rig.hid.failGet = false
        rig.runtime.checkHealth()
        #expect(rig.runtime.status == .off)
        #expect(rig.tap?.isStopped == true)
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func aFailedRestoreAfterTheTapDiedSaysWhyOnceItWorks() {
        let rig = Rig()
        rig.runtime.sync(config(superBindings))
        rig.tap?.isEnabled = false
        rig.tap?.canReenable = false
        rig.hid.failGet = true
        rig.runtime.checkHealth()
        guard case .capsLockStuck = rig.runtime.status else {
            Issue.record("expected capsLockStuck, got \(rig.runtime.status)")
            return
        }
        #expect(rig.tap?.isStopped == true)

        rig.hid.failGet = false
        rig.runtime.checkHealth()
        #expect(rig.runtime.status == .failed("macOS turned the Super key off and it couldn't be turned back on"))
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func aKeyboardPluggedInGetsTheRemapWithinTenSeconds() {
        let rig = Rig()
        rig.runtime.sync(config(superBindings))
        rig.hid.keyboards.append([])
        for _ in 0 ..< 5 { rig.runtime.checkHealth() } // Every 2 seconds
        #expect(rig.hid.keyboards == [[capsToF18], [capsToF18]])
        rig.runtime.stop()
        #expect(rig.hid.keyboards == [[], []])
    }

    /// The last run died with Caps Lock remapped
    @Test func startGivesCapsLockBack() {
        let rig = Rig()
        _ = rig.remap.apply()
        #expect(rig.hid.keyboards == [[capsToF18]])
        rig.runtime.start()
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func superWorksWhileRecordingBeforeABindingUsesIt() {
        let rig = Rig()
        let withoutSuper = config(optionBindings)
        rig.runtime.setRecording(true, withoutSuper)
        #expect(rig.runtime.status == .on(.capsLock))
        rig.runtime.setRecording(false, withoutSuper)
        #expect(rig.runtime.status == .off)
        #expect(rig.hid.keyboards == [[]])
    }

    @Test func nothingHappensBeforeStart() {
        let hid = FakeHidutil([[]])
        let markerUrl = FileManager.default.temporaryDirectory.appending(path: "super-key-runtime-\(UUID().uuidString).json")
        let runtime = SuperKeyRuntime(
            remap: CapsLockRemap(hidutil: { try hid.run($0) }, markerUrl: markerUrl),
            startTap: { _ in
                Issue.record("tap started")
                return nil
            },
            isTrusted: { true },
            turnCapsLockOff: {},
        )
        runtime.sync(config(superBindings))
        runtime.setRecording(true, config(superBindings))
        #expect(hid.calls == 0)
    }
}
