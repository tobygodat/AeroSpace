@testable import AppBundle
import Foundation
import Testing

private let capsToF18 = HidKeyMapping(src: capsLockUsage, dst: f18Usage)
private let capsToControl = HidKeyMapping(src: capsLockUsage, dst: 0x7_0000_00E0)
private let swapAB = HidKeyMapping(src: 0x7_0000_0004, dst: 0x7_0000_0005)

/// hidutil for keyboard services that live in memory. Never touches the real HID system
private final class FakeHidutil: @unchecked Sendable {
    var keyboards: [[HidKeyMapping]]
    var sets: [[HidKeyMapping]] = []
    var calls = 0
    var failGet = false
    var failSet = false

    init(_ keyboards: [[HidKeyMapping]]) { self.keyboards = keyboards }

    func run(_ arguments: [String]) throws -> String {
        calls += 1
        #expect(Array(arguments.prefix(3)) == ["property", "--matching", "keyboard"])
        switch arguments[3] {
            case "--get":
                if failGet { throw HidutilError(description: "boom") }
                return "RegistryID  Key                   Value\n" + keyboards.enumerated().map { index, list in
                    "10000\(index)fea   UserKeyMapping   " + render(list)
                }.joined(separator: "\n") + "\n"
            case "--set":
                if failSet { throw HidutilError(description: "refused") }
                let json = try JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as! [String: [[String: UInt64]]]
                let list = json["UserKeyMapping"]!.map { HidKeyMapping(src: $0["HIDKeyboardModifierMappingSrc"]!, dst: $0["HIDKeyboardModifierMappingDst"]!) }
                sets.append(list)
                keyboards = keyboards.map { _ in list }
                return ""
            default:
                Issue.record("unexpected hidutil \(arguments)")
                return ""
        }
    }

    /// The way hidutil prints a UserKeyMapping value
    private func render(_ list: [HidKeyMapping]) -> String {
        if list.isEmpty { return "(null)" }
        let entries = list.map {
            "        {\n        HIDKeyboardModifierMappingDst = \($0.dst);\n        HIDKeyboardModifierMappingSrc = \($0.src);\n    }"
        }
        return "(\n" + entries.joined(separator: ",\n") + "\n)"
    }
}

@Suite final class CapsLockRemapTest {
    private let dir = FileManager.default.temporaryDirectory.appending(path: "caps-lock-remap-\(UUID().uuidString)")
    private var markerUrl: URL { dir.appending(path: "caps-lock-remap.json") }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func remap(_ fake: FakeHidutil) -> CapsLockRemap {
        CapsLockRemap(hidutil: { try fake.run($0) }, markerUrl: markerUrl)
    }

    private var hasMarker: Bool { FileManager.default.fileExists(atPath: markerUrl.path) }

    @Test func applyThenRestoreWithNoMappings() {
        let fake = FakeHidutil([[]])
        #expect(remap(fake).apply().failureOrNil == nil)
        #expect(fake.keyboards == [[capsToF18]])
        #expect(hasMarker)
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.keyboards == [[]])
        #expect(!hasMarker)
    }

    @Test func otherMappingsAreKept() {
        let fake = FakeHidutil([[swapAB], [swapAB]])
        _ = remap(fake).apply()
        #expect(fake.keyboards == [[swapAB, capsToF18], [swapAB, capsToF18]])
        _ = remap(fake).restore()
        #expect(fake.keyboards == [[swapAB], [swapAB]])
    }

    @Test func previousCapsLockMappingComesBack() {
        let fake = FakeHidutil([[capsToControl, swapAB]])
        _ = remap(fake).apply()
        #expect(fake.keyboards == [[swapAB, capsToF18]])
        _ = remap(fake).restore()
        #expect(fake.keyboards == [[swapAB, capsToControl]])
    }

    /// AeroSpace crashed with Caps Lock remapped: the next launch restores before anything else
    @Test func crashRecoveryAtNextLaunch() {
        let fake = FakeHidutil([[capsToControl]])
        _ = remap(fake).apply()
        let nextLaunch = remap(fake)
        #expect(nextLaunch.restore().failureOrNil == nil)
        #expect(fake.keyboards == [[capsToControl]])
    }

    /// Applying again before a restore (a crash, then a launch that skipped recovery) must not save F18 as the original
    @Test func applyTwiceKeepsTheOriginal() {
        let fake = FakeHidutil([[capsToControl]])
        _ = remap(fake).apply()
        let setsAfterFirst = fake.sets.count
        #expect(remap(fake).apply().failureOrNil == nil)
        #expect(fake.sets.count == setsAfterFirst, "already remapped: no second set")
        _ = remap(fake).restore()
        #expect(fake.keyboards == [[capsToControl]])
    }

    @Test func restoreWithoutMarkerDoesNothing() {
        let fake = FakeHidutil([[capsToF18]]) // Somebody's own Caps Lock → F18
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.calls == 0)
        #expect(fake.keyboards == [[capsToF18]])
    }

    @Test func restoreLeavesSomeoneElsesNewCapsLockMapping() {
        let fake = FakeHidutil([[]])
        _ = remap(fake).apply()
        fake.keyboards = [[capsToControl]] // Changed by another tool while AeroSpace ran
        let setsBefore = fake.sets.count
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.sets.count == setsBefore)
        #expect(fake.keyboards == [[capsToControl]])
        #expect(!hasMarker)
    }

    /// After a reboot the remap is gone but the marker is still there
    @Test func restoreAfterRebootOnlyDropsTheMarker() {
        let fake = FakeHidutil([[swapAB]])
        _ = remap(fake).apply()
        fake.keyboards = [[]]
        let setsBefore = fake.sets.count
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.sets.count == setsBefore)
        #expect(!hasMarker)
    }

    @Test func keyboardsWithDifferentRemapsAreLeftAlone() {
        let fake = FakeHidutil([[swapAB], []])
        guard case .failure(let message) = remap(fake).apply() else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("Modifier Keys"))
        #expect(fake.sets.isEmpty)
        #expect(!hasMarker)
    }

    @Test func failedSetLeavesNoMarker() {
        let fake = FakeHidutil([[]])
        fake.failSet = true
        #expect(remap(fake).apply().failureOrNil?.contains("refused") == true)
        #expect(fake.keyboards == [[]])
        #expect(!hasMarker)
    }

    @Test func failedRestoreKeepsTheMarkerAndSaysHowToUndo() {
        let fake = FakeHidutil([[]])
        _ = remap(fake).apply()
        fake.failGet = true
        let message = remap(fake).restore().failureOrNil ?? ""
        #expect(message.contains("hidutil property --set '{\"UserKeyMapping\":[]}'"))
        #expect(hasMarker, "the next launch tries again")
    }

    @Test func parsesHidutilOutput() {
        let table = """
            RegistryID  Key                   Value
            100000cb6   UserKeyMapping   (null)
            100000fea   UserKeyMapping   (
                    {
                    HIDKeyboardModifierMappingDst = 30064771300;
                    HIDKeyboardModifierMappingSrc = 30064771129;
                },
                    {
                    HIDKeyboardModifierMappingDst = 0x700000005;
                    HIDKeyboardModifierMappingSrc = 0x700000004;
                }
            )

            """
        #expect(parseUserKeyMappings(table) == [[], [HidKeyMapping(src: capsLockUsage, dst: 0x7_0000_00E4), swapAB]])
        let bare = "(\n    {\n    HIDKeyboardModifierMappingDst = 30064771181;\n    HIDKeyboardModifierMappingSrc = 30064771129;\n}\n)\n"
        #expect(parseUserKeyMappings(bare) == [[capsToF18]])
        #expect(parseUserKeyMappings("(null)\n") == [[]])
    }

    @Test func setJson() {
        #expect(userKeyMappingJson([]) == #"{"UserKeyMapping":[]}"#)
        #expect(userKeyMappingJson([capsToF18]) == #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#)
    }
}

@Suite final class CapsLockRemapNewKeyboardTest {
    private let markerUrl = FileManager.default.temporaryDirectory.appending(path: "caps-lock-remap-\(UUID().uuidString).json")

    deinit { try? FileManager.default.removeItem(at: markerUrl) }

    /// A keyboard plugged in after the remap has no Caps Lock entry yet. Applying again covers it instead of refusing
    @Test func keyboardPluggedInLaterGetsTheRemap() {
        let fake = FakeHidutil([[swapAB]])
        let remap = CapsLockRemap(hidutil: { try fake.run($0) }, markerUrl: markerUrl)
        _ = remap.apply()
        fake.keyboards.append([swapAB])
        #expect(remap.apply().failureOrNil == nil)
        #expect(fake.keyboards == [[swapAB, capsToF18], [swapAB, capsToF18]])
        _ = remap.restore()
        #expect(fake.keyboards == [[swapAB], [swapAB]])
    }
}
