@testable import AppBundle
import Foundation
import Testing

let capsToF18 = HidKeyMapping(src: capsLockUsage, dst: f18Usage)
private let capsToControl = HidKeyMapping(src: capsLockUsage, dst: 0x7_0000_00E0)
private let capsToEscape = HidKeyMapping(src: capsLockUsage, dst: 0x7_0000_0029)
private let swapAB = HidKeyMapping(src: 0x7_0000_0004, dst: 0x7_0000_0005)
/// What System Settings → Modifier Keys writes for a PC keyboard: ⌥ and ⌘ swapped
private let swapOptionCommand = HidKeyMapping(src: 0x7_0000_00E2, dst: 0x7_0000_00E3)

/// hidutil for keyboard services that live in memory. Never touches the real HID system
final class FakeHidutil: @unchecked Sendable {
    /// One per keyboard service, in the order hidutil lists them
    var keyboards: [[HidKeyMapping]]
    var sets = 0
    var calls = 0
    var failGet = false
    var failSet = false

    init(_ keyboards: [[HidKeyMapping]]) { self.keyboards = keyboards }

    func run(_ arguments: [String]) throws -> String {
        calls += 1
        if failGet && !arguments.contains("--set") { throw HidutilError(description: "boom") }
        switch arguments {
            case ["list", "--matching", "keyboard"]:
                return "Services:\nVendorID ProductID LocationID UsagePage Usage RegistryID  Transport Class    Product      UserClass Built-In \n"
                    + keyboards.indices.map { "0x5ac    0x\(index: $0)  0x\(index: $0 + 0xA0) 1         6     0x10000\(index: $0)fea USB       AppleHID Keyboard \($0) (null)    0        " }
                    .joined(separator: "\n")
                    + "\n\nDevices:\nVendorID ProductID LocationID UsagePage Usage RegistryID  Transport Class Product UserClass Built-In \n0x5ac 0x0 0xa0 1 6 0x100000aaa USB AppleHIDDevice Keyboard (null) 0\n"
            case ["property", "--matching", "keyboard", "--get", "UserKeyMapping"]:
                return "RegistryID  Key                   Value\n" + keyboards.enumerated().map { index, list in
                    "10000\(index: index)fea   UserKeyMapping   " + render(list)
                }.joined(separator: "\n") + "\n"
            case _ where arguments.count == 5 && arguments[0] == "property" && arguments[3] == "--set":
                if failSet { throw HidutilError(description: "refused") }
                let matching = try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as! [String: UInt64]
                #expect(matching["PrimaryUsagePage"] == 1 && matching["PrimaryUsage"] == 6, "only keyboards")
                let index = Int(matching["ProductID"]!)
                #expect(matching == ["VendorID": 0x5AC, "ProductID": UInt64(index), "LocationID": UInt64(index + 0xA0), "PrimaryUsagePage": 1, "PrimaryUsage": 6])
                let json = try JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as! [String: [[String: UInt64]]]
                keyboards[index] = json["UserKeyMapping"]!.map { HidKeyMapping(src: $0["HIDKeyboardModifierMappingSrc"]!, dst: $0["HIDKeyboardModifierMappingDst"]!) }
                sets += 1
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

private extension String.StringInterpolation {
    mutating func appendInterpolation(index: Int) { appendLiteral(String(index, radix: 16)) }
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

    /// A PC keyboard with ⌥ and ⌘ swapped next to the built-in one: each keeps its own remaps
    @Test func eachKeyboardKeepsItsOwnMappings() {
        let fake = FakeHidutil([[], [swapOptionCommand, swapAB]])
        #expect(remap(fake).apply().failureOrNil == nil)
        #expect(fake.keyboards == [[capsToF18], [swapOptionCommand, swapAB, capsToF18]])
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.keyboards == [[], [swapOptionCommand, swapAB]])
    }

    @Test func eachKeyboardGetsItsOwnCapsLockMappingBack() {
        let fake = FakeHidutil([[capsToControl, swapAB], [capsToEscape], []])
        _ = remap(fake).apply()
        #expect(fake.keyboards == [[swapAB, capsToF18], [capsToF18], [capsToF18]])
        _ = remap(fake).restore()
        #expect(fake.keyboards == [[swapAB, capsToControl], [capsToEscape], []])
    }

    /// AeroSpace crashed with Caps Lock remapped: the next launch restores before anything else
    @Test func crashRecoveryAtNextLaunch() {
        let fake = FakeHidutil([[capsToControl]])
        _ = remap(fake).apply()
        let nextLaunch = remap(fake)
        #expect(nextLaunch.restore().failureOrNil == nil)
        #expect(fake.keyboards == [[capsToControl]])
    }

    /// Applying again before a restore must neither write again nor save F18 as the original
    @Test func applyTwiceKeepsTheOriginal() {
        let fake = FakeHidutil([[capsToControl]])
        _ = remap(fake).apply()
        let setsAfterFirst = fake.sets
        #expect(remap(fake).apply().failureOrNil == nil)
        #expect(fake.sets == setsAfterFirst, "already remapped: no second set")
        _ = remap(fake).restore()
        #expect(fake.keyboards == [[capsToControl]])
    }

    /// Applying again covers a keyboard plugged in since, and leaves the others alone
    @Test func keyboardPluggedInLaterGetsTheRemap() {
        let fake = FakeHidutil([[swapAB]])
        _ = remap(fake).apply()
        fake.keyboards.append([capsToEscape, swapOptionCommand])
        let setsBefore = fake.sets
        #expect(remap(fake).apply().failureOrNil == nil)
        #expect(fake.sets == setsBefore + 1)
        #expect(fake.keyboards == [[swapAB, capsToF18], [swapOptionCommand, capsToF18]])
        _ = remap(fake).restore()
        #expect(fake.keyboards == [[swapAB], [swapOptionCommand, capsToEscape]])
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
        let setsBefore = fake.sets
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.sets == setsBefore)
        #expect(fake.keyboards == [[capsToControl]])
        #expect(!hasMarker)
    }

    /// After a reboot the remap is gone but the marker is still there
    @Test func restoreAfterRebootOnlyDropsTheMarker() {
        let fake = FakeHidutil([[swapAB]])
        _ = remap(fake).apply()
        fake.keyboards = [[swapAB]]
        let setsBefore = fake.sets
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.sets == setsBefore)
        #expect(!hasMarker)
    }

    /// A refresh that can't write must keep what the first apply saved, so a restore still puts Caps Lock back
    @Test func failedRefreshKeepsTheMarker() {
        let fake = FakeHidutil([[capsToControl]])
        _ = remap(fake).apply()
        fake.keyboards.append([])
        fake.failSet = true
        #expect(remap(fake).apply().failureOrNil?.contains("refused") == true)
        #expect(hasMarker)
        fake.failSet = false
        #expect(remap(fake).restore().failureOrNil == nil)
        #expect(fake.keyboards == [[capsToControl], []])
    }

    @Test func failedRestoreKeepsTheMarkerAndSaysHowToUndo() {
        let fake = FakeHidutil([[]])
        _ = remap(fake).apply()
        fake.failGet = true
        let message = remap(fake).restore().failureOrNil ?? ""
        #expect(message.contains("hidutil property --set '{\"UserKeyMapping\":[]}'"))
        #expect(hasMarker, "the next try still knows what to put back")
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
        let parsed = parseUserKeyMappings(table)
        #expect(parsed.map(\.registryID) == [0x1_0000_0CB6, 0x1_0000_0FEA])
        #expect(parsed.map(\.mappings) == [[], [HidKeyMapping(src: capsLockUsage, dst: 0x7_0000_00E4), swapAB]])
        let bare = "(\n    {\n    HIDKeyboardModifierMappingDst = 30064771181;\n    HIDKeyboardModifierMappingSrc = 30064771129;\n}\n)\n"
        #expect(parseUserKeyMappings(bare).map(\.mappings) == [[capsToF18]])
        #expect(parseUserKeyMappings(bare).map(\.registryID) == [nil])
        #expect(parseUserKeyMappings("(null)\n").map(\.mappings) == [[]])
    }

    /// `hidutil list --matching keyboard` on macOS 27, plus a row whose IDs aren't numbers
    @Test func parsesKeyboardServices() {
        let list = """
            Services:
            VendorID ProductID LocationID UsagePage Usage RegistryID  Transport Class                         Product                            UserClass Built-In 
            0x0      0x0       0xa7       1         6     0x100000fea FIFO      AppleHIDKeyboardEventDriverV2 Apple Internal Keyboard / Trackpad (null)    1        
            (null)   (null)    (null)     1         6     0x100000abc Virtual   SomeVirtualKeyboard           Virtual Keyboard                   (null)    0        

            Devices:
            VendorID ProductID LocationID UsagePage Usage RegistryID  Transport Class                      Product                            UserClass Built-In 
            0x0      0x0       0xa7       1         6     0x100000fd4 FIFO      AppleHIDTransportHIDDevice Apple Internal Keyboard / Trackpad (null)    1        

            """
        let services = parseKeyboardServices(list)
        #expect(services.map(\.registryID) == [0x1_0000_0FEA])
        #expect(services.map(\.matching) == [#"{"VendorID":0,"ProductID":0,"LocationID":167,"PrimaryUsagePage":1,"PrimaryUsage":6}"#])
    }

    @Test func setJson() {
        #expect(userKeyMappingJson([]) == #"{"UserKeyMapping":[]}"#)
        #expect(userKeyMappingJson([capsToF18]) == #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#)
    }
}
