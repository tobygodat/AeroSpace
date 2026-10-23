// swift-testing rather than XCTest, so these run with the Command Line Tools alone:
//   AEROSPACE_SKIP_XCTEST=1 swift test --filter KeybindingEditorTests
@testable import AppBundle
import AppKit
import Common
import Foundation
import Testing

private let sample = """
    config-version = 2
    gaps.inner.horizontal = 10 # [not a header]

    [mode.main.binding]
        # Apps
        alt-enter = '''exec-and-forget osascript -e 'tell application "Terminal" to activate' ''' # terminal
        alt-b = 'exec-and-forget open -a "Safari"'

        # Windows
        alt-w = 'close'
        alt-x = [
            'layout floating tiling',
            'mode main', # [still inside the array]
        ]
        alt-1 = 'workspace 1'

    [mode.service.binding]
        esc = ['reload-config', 'mode main']
        r = ['flatten-workspace-tree', 'mode main']

    [[on-window-detected]]
        if.app-id = 'com.apple.finder'
        run = 'layout floating'

    """

private let projectRoot: URL = {
    var url = URL(filePath: #filePath).absoluteURL
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    return url
}()

private func modes(_ toml: String) -> [EditableMode] { readEditableModes(toml).getOrDie() }

private func rewrite(_ toml: String, _ edit: (inout [EditableMode]) -> Void) -> String {
    var modes = modes(toml)
    edit(&modes)
    return rewriteBindings(toml, modes).getOrDie()
}

@MainActor
struct EditableBindingsTest {
    @Test func readKeepsFileOrderAndValues() {
        let modes = modes(sample)
        #expect(modes.map(\.name) == ["main", "service"])
        #expect(modes[0].bindings.map(\.key) == ["alt-enter", "alt-b", "alt-w", "alt-x", "alt-1"])
        #expect(modes[0].bindings[0].commands == [#"exec-and-forget osascript -e 'tell application "Terminal" to activate' "#])
        #expect(modes[0].bindings[3].commands == ["layout floating tiling", "mode main"])
        #expect(modes[1].bindings[0].commands == ["reload-config", "mode main"])
    }

    @Test(arguments: ["default-config.toml", "i3-like-config-example.toml"])
    func unchangedRoundTripIsByteIdentical(example: String) throws {
        #expect(rewrite(sample) { _ in } == sample)
        let toml = try String(contentsOf: projectRoot.appending(component: "docs/config-examples/\(example)"), encoding: .utf8)
        #expect(rewrite(toml) { _ in } == toml)
    }

    @Test func changeCommandOnlyTouchesThatLine() {
        let result = rewrite(sample) { $0[0].bindings[2].commands = ["fullscreen"] }
        #expect(result == sample.replacingOccurrences(of: "alt-w = 'close'", with: "alt-w = 'fullscreen'"))
    }

    @Test func renameKeyKeepsValueTextAndComment() {
        let result = rewrite(sample) { $0[0].bindings[0].key = "cmd-enter" }
        #expect(result == sample.replacingOccurrences(of: "    alt-enter = '''", with: "    cmd-enter = '''"))
    }

    @Test func replaceMultilineEntry() {
        let result = rewrite(sample) { $0[0].bindings[3].commands = ["layout floating tiling"] }
        let expected = sample.replacingOccurrences(
            of: """
                    alt-x = [
                        'layout floating tiling',
                        'mode main', # [still inside the array]
                    ]
                """,
            with: "    alt-x = 'layout floating tiling'",
        )
        #expect(result == expected)
    }

    @Test func deleteAndAdd() {
        let result = rewrite(sample) {
            $0[0].bindings.removeAll { $0.key == "alt-b" }
            $0[0].bindings.append(EditableBinding(originalKey: nil, key: "alt-2", commands: ["workspace 2"]))
        }
        let expected = sample
            .replacingOccurrences(of: "    alt-b = 'exec-and-forget open -a \"Safari\"'\n", with: "")
            .replacingOccurrences(of: "    alt-1 = 'workspace 1'\n", with: "    alt-1 = 'workspace 1'\n    alt-2 = 'workspace 2'\n")
        #expect(result == expected)
    }

    @Test func addsSectionForModeWithoutOne() {
        let toml = "config-version = 2\n[mode.main.binding]\n"
        let result = rewrite(toml) {
            $0.append(EditableMode(name: "resize", bindings: [EditableBinding(originalKey: nil, key: "h", commands: ["resize width -50"])]))
        }
        #expect(result == "config-version = 2\n[mode.main.binding]\n\n[mode.resize.binding]\n    h = 'resize width -50'\n")
    }

    @Test func quotedHeader() {
        let toml = "[mode.\"main\".binding]\nalt-a = 'close'\n"
        #expect(rewrite(toml) { $0[0].bindings[0].commands = ["fullscreen"] } == "[mode.\"main\".binding]\nalt-a = 'fullscreen'\n")
    }

    @Test func refusesBindingsDefinedElsewhere() {
        let toml = "[mode.main]\nbinding.alt-a = 'close'\n"
        var modes = modes(toml)
        modes[0].bindings.append(EditableBinding(originalKey: nil, key: "alt-b", commands: ["fullscreen"]))
        #expect(!rewriteBindings(toml, modes).isSuccess)
    }

    @Test func serializeStrings() {
        #expect(serializeTomlString("workspace 1") == "'workspace 1'")
        #expect(serializeTomlString("open -a \"Safari\"") == "'open -a \"Safari\"'")
        #expect(serializeTomlString("it's") == "\"it's\"")
        #expect(serializeTomlString(#"say 'a' "b""#) == #"'''say 'a' "b"'''"#)
        #expect(serializeTomlString("ends with '") == "\"ends with '\"")
        #expect(serializeTomlString("a\nb") == "\"a\\nb\"")
        for value in ["plain", "it's", #"say 'a' "b""#, "ends with '", "a\nb", #"back\slash 'q' "d""#] {
            let binding = EditableBinding(originalKey: nil, key: "alt-a", commands: [value])
            let read = readEditableModes("[mode.main.binding]\n" + serializeBinding(binding)).getOrDie()
            #expect(read[0].bindings[0].commands == [value])
        }
        #expect(serializeTomlKey("alt-shift-1") == "alt-shift-1")
        #expect(serializeTomlKey("weird key") == "\"weird key\"")
    }

    @Test func prettyShortcuts() {
        #expect(prettyShortcut("alt-shift-1") == "⌥⇧1")
        #expect(prettyShortcut("cmd-ctrl-enter") == "⌃⌘↩")
        #expect(prettyShortcut("alt-b") == "⌥B")
    }

    @Test func omarchyPresetParses() {
        for superKey in ["alt", "cmd"] {
            let toml = "config-version = 2\n[mode.main.binding]\n" + omarchyBindings(superKey: superKey)
                .map { serializeBinding(EditableBinding(originalKey: nil, key: $0.key, commands: [$0.command])) }
                .joined(separator: "\n")
            #expect(parseConfig(toml).errors == [])
        }
    }
}

@MainActor
final class KeybindingEditorModelTest {
    private let url: URL = FileManager.default.temporaryDirectory.appending(path: "keybinding-editor-\(UUID().uuidString).toml")
    private var saves = 0

    init() throws {
        try sample.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak-keybindings"))
    }

    private func makeModel() -> KeybindingEditorModel {
        let model = KeybindingEditorModel(configUrlProvider: { [url] in .success(url) }, afterSave: { self.saves += 1 })
        model.load()
        return model
    }

    @Test func recordShortcut() {
        let model = makeModel()
        let id = model.modes[0].bindings[1].id
        model.startRecording(id)
        model.record(keyCode: 18, modifierFlags: [.option, .shift, .capsLock]) // "1"
        #expect(model.modes[0].bindings[1].key == "alt-shift-1")
        #expect(model.recordingBindingId == nil)

        model.startRecording(id)
        model.record(keyCode: 53, modifierFlags: []) // esc cancels
        #expect(model.modes[0].bindings[1].key == "alt-shift-1")
        #expect(model.recordingBindingId == nil)

        model.startRecording(id)
        model.record(keyCode: 36, modifierFlags: [.command]) // enter
        #expect(model.modes[0].bindings[1].key == "cmd-enter")
    }

    @Test func validation() {
        let model = makeModel()
        let mode = model.modes[0]
        #expect(model.errors(for: mode.bindings[0], in: mode) == [])

        var duplicate = mode.bindings[1]
        duplicate.key = "alt-w"
        model.modes[0].bindings[1] = duplicate
        #expect(model.errors(for: duplicate, in: model.modes[0]).count == 1)
        #expect(model.hasErrors)

        let bad = EditableBinding(originalKey: nil, key: "alt-nope", commands: ["not-a-command"])
        #expect(model.errors(for: bad, in: model.modes[0]).count == 2)
        #expect(model.warning(for: EditableBinding(originalKey: nil, key: "alt-left", commands: ["focus left"])) != nil)
    }

    @Test func saveWritesFileAndReloads() async throws {
        let model = makeModel()
        model.modes[0].bindings[2].commands = ["fullscreen"]
        #expect(model.isDirty)
        await model.save()
        #expect(model.status?.isError == false)
        #expect(!model.isDirty)
        #expect(saves == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == sample.replacingOccurrences(of: "alt-w = 'close'", with: "alt-w = 'fullscreen'"))
        #expect(try String(contentsOf: url.appendingPathExtension("bak-keybindings"), encoding: .utf8) == sample)

        // A second edit after saving updates the line written by the first save
        model.modes[0].bindings[2].key = "alt-q"
        await model.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == sample.replacingOccurrences(of: "alt-w = 'close'", with: "alt-q = 'fullscreen'"))
    }

    @Test func saveRefusesWhenFileChangedOnDisk() async throws {
        let model = makeModel()
        model.modes[0].bindings[2].commands = ["fullscreen"]
        try (sample + "\n# edited elsewhere\n").write(to: url, atomically: true, encoding: .utf8)
        await model.save()
        #expect(model.status?.isError == true)
        #expect(model.isDirty)
    }

    @Test func applyPresetReusesExistingLines() {
        let model = makeModel()
        model.apply(KeybindingPreset(name: "Test", bindings: [("alt-w", "close"), ("alt-f", "fullscreen")]))
        #expect(model.modes[0].bindings.map(\.key) == ["alt-w", "alt-f"])
        #expect(model.modes[0].bindings[0].originalKey == "alt-w")
        #expect(model.modes[0].bindings[1].originalKey == nil)
    }
}
