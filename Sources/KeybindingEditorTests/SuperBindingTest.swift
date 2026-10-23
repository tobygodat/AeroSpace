@testable import AppBundle
import AppKit
import Common
import Foundation
import Testing

@MainActor private func config(_ toml: String) -> ParseConfigResult { parseConfig("config-version = 2\n" + toml) }

private func binding(_ result: ParseConfigResult, _ key: String) -> HotkeyBinding? {
    result.config.modes[mainModeId]?.bindings.values.first { $0.descriptionWithKeyNotation == key }
}

@MainActor
@Suite struct SuperGrammarTest {
    @Test func superIsAModifierOfItsOwn() {
        let parsed = config("""
            [mode.main.binding]
            super-b = 'workspace 1'
            super-shift-b = 'workspace 2'
            super-ctrl-b = 'workspace 3'
            ctrl-alt-cmd-b = 'workspace 4'
            ctrl-alt-cmd-shift-b = 'workspace 5'
            alt-b = 'workspace 6'
            """)
        #expect(parsed.errors == [])
        let keys = Set(parsed.config.modes[mainModeId]?.bindings.keys.map { $0 } ?? [])
        #expect(keys == ["super-b", "super-shift-b", "super-ctrl-b", "alt-ctrl-cmd-b", "alt-ctrl-cmd-shift-b", "alt-b"])
        #expect(binding(parsed, "super-ctrl-b")?.modifiers == [.superKey, .control])
        #expect(binding(parsed, "ctrl-alt-cmd-b")?.modifiers == [.control, .option, .command])
    }

    @Test func superOnCapsLockOrRightCommandIsNotACarbonHotkey() {
        let superShift: HotkeyModifiers = [.superKey, .shift]
        for superKey in [SuperKey.capsLock, .rightCmd, .capsLockOrRightCmd] {
            #expect(superShift.carbonFlags(superKey) == nil)
        }
        #expect(superShift.carbonFlags(.alt) == [.option, .shift])
        #expect(superShift.carbonFlags(.cmd) == [.command, .shift])
        #expect(HotkeyModifiers([.control, .option]).carbonFlags(.capsLock) == [.control, .option])
    }

    @Test func superKeySetting() {
        #expect(config("").config.superKey == .capsLock)
        #expect(config("super-key = 'right-cmd'").config.superKey == .rightCmd)
        #expect(config("super-key = 'caps-lock-or-right-cmd'").config.superKey == .capsLockOrRightCmd)
        let bad = config("super-key = 'hyper'")
        #expect(bad.errors.map(\.message) == ["Can't parse super-key 'hyper'. Possible values: 'caps-lock', 'right-cmd', 'caps-lock-or-right-cmd', 'alt', 'cmd'"])
    }

    @Test func superAndItsModifierClashWhenSuperIsThatModifier() {
        let bindings = """
            [mode.main.binding]
            alt-b = 'workspace 1'
            super-b = 'workspace 2'
            """
        #expect(config("super-key = 'caps-lock'\n" + bindings).errors == [])
        #expect(config("super-key = 'cmd'\n" + bindings).errors == [])
        let clash = config("super-key = 'alt'\n" + bindings).errors.map(\.message)
        #expect(clash.count == 1)
        #expect(clash.first?.contains("are the same keys while super-key = 'alt'") == true)
    }

    @Test func usesSuperModifier() {
        #expect(!config("[mode.main.binding]\nalt-b = 'workspace 1'").config.usesSuperModifier)
        #expect(config("[mode.main.binding]\nalt-b = 'workspace 1'\n[mode.service.binding]\nsuper-r = 'reload-config'").config.usesSuperModifier)
    }

    @Test func omarchyPresetUsesSuper() {
        let bindings = omarchyBindings(superKey: "super")
        #expect(bindings.allSatisfy { $0.key.hasPrefix("super-") })
        #expect(bindings.contains { $0.key == "super-shift-1" })
        #expect(bindings.contains { $0.key == "super-ctrl-tab" })
        for superKey in SuperKey.allCases {
            let toml = "super-key = '\(superKey.rawValue)'\n[mode.main.binding]\n" + bindings
                .map { serializeBinding(EditableBinding(originalKey: nil, key: $0.key, commands: [$0.command])) }
                .joined(separator: "\n")
            #expect(config(toml).errors == [], "super-key = \(superKey.rawValue)")
        }
    }

    /// The Apps pane (PR #1) takes Super from the modifiers of the binding that runs `workspace 1`
    @Test func superInferredFromWorkspaceOneBinding() {
        guard case .success(let (modifiers, _)) = parseBinding("super-1", .emptyRoot, keyNotationToKeyCode) else {
            Issue.record("super-1 doesn't parse")
            return
        }
        #expect(modifiers.toString() == "super")
    }

    @Test func shortcutsShowSuperAsDiamond() {
        #expect(prettyShortcut("super-shift-1") == "◆⇧1")
        #expect(prettyShortcut("super-ctrl-tab") == "◆⌃⇥")
        #expect(shortcutSymbols("super-b") == ["◆", "B"])
    }
}

// MARK: Converting ⌥ bindings

private let optionConfig = """
    config-version = 2
    super-key = 'caps-lock' # the default

    [mode.main.binding]
        alt-1 = 'workspace 1' # first
        alt-shift-1 = 'move-node-to-workspace 1'
        ctrl-alt-left = 'move-workspace-to-monitor left'
        alt-b = 'exec-and-forget open -a Safari'
        super-b = 'close'
        cmd-h = 'fullscreen'

    [mode.service.binding]
        alt-shift-h = ['join-with left', 'mode main']
        esc = 'mode main'
    """

@MainActor
@Suite struct ConvertOptionBindingsTest {
    @Test func swapsOnlyTheModifierAndKeepsEverythingElse() throws {
        let modes = try readEditableModes(optionConfig).get()
        let swap = swapBindingModifier("alt", "super", in: modes)
        #expect(swap.skipped == [ModeBindingKey(mode: "main", key: "alt-b")]) // super-b is taken
        #expect(swap.swapped.map(\.key) == ["super-1", "super-shift-1", "ctrl-super-left", "super-shift-h"])

        let text = try rewriteBindings(optionConfig, swap.modes).get()
        let before = splitLines(optionConfig)
        let after = splitLines(text)
        #expect(before.count == after.count)
        let changed = zip(before, after).filter { $0 != $1 }
        #expect(changed.map(\.1) == [
            "    super-1 = 'workspace 1' # first",
            "    super-shift-1 = 'move-node-to-workspace 1'",
            "    ctrl-super-left = 'move-workspace-to-monitor left'",
            "    super-shift-h = ['join-with left', 'mode main']",
        ])
        #expect(parseConfig(text).errors == [])
    }

    @Test func undoRestoresTheFileByteForByte() throws {
        let modes = try readEditableModes(optionConfig).get()
        let swap = swapBindingModifier("alt", "super", in: modes)
        let converted = try rewriteBindings(optionConfig, swap.modes).get()
        let back = swapBindingModifier("super", "alt", in: try readEditableModes(converted).get(), only: Set(swap.swapped))
        #expect(back.swapped.count == swap.swapped.count) // super-b, which was there before, stays
        #expect(try rewriteBindings(converted, back.modes).get() == optionConfig)
    }

    @Test func modifierOrderDoesNotHideAClash() throws {
        let modes = [EditableMode(name: "main", bindings: [
            EditableBinding(originalKey: "shift-alt-x", key: "shift-alt-x", commands: ["close"]),
            EditableBinding(originalKey: "super-shift-x", key: "super-shift-x", commands: ["fullscreen"]),
        ])]
        let swap = swapBindingModifier("alt", "super", in: modes)
        #expect(swap.swapped.isEmpty)
        #expect(swap.skipped.map(\.key) == ["shift-alt-x"])
    }
}

// MARK: Writing super-key

@Suite struct SuperKeySettingTest {
    @Test func editsTheExistingLineAndKeepsItsComment() throws {
        let text = try rewriteSuperKeySetting(optionConfig, .rightCmd).get()
        #expect(text == optionConfig.replacingOccurrences(of: "super-key = 'caps-lock' # the default", with: "super-key = 'right-cmd' # the default"))
    }

    @Test func addsALineAfterTheLastTopLevelSetting() throws {
        let toml = "config-version = 2\ngaps.inner.horizontal = 10\n\n[mode.main.binding]\nalt-1 = 'workspace 1'\n"
        let text = try rewriteSuperKeySetting(toml, .capsLockOrRightCmd).get()
        #expect(text == "config-version = 2\ngaps.inner.horizontal = 10\nsuper-key = 'caps-lock-or-right-cmd'\n\n[mode.main.binding]\nalt-1 = 'workspace 1'\n")
    }

    @Test func addsALineBeforeTheFirstTableWhenThereAreNoTopLevelSettings() throws {
        let toml = "# My config\n[mode.main.binding]\nalt-1 = 'workspace 1'\n"
        #expect(try rewriteSuperKeySetting(toml, .alt).get() == "# My config\nsuper-key = 'alt'\n\n[mode.main.binding]\nalt-1 = 'workspace 1'\n")
        #expect(try rewriteSuperKeySetting("", .cmd).get() == "super-key = 'cmd'\n")
        #expect(try rewriteSuperKeySetting("# nothing\n", .cmd).get() == "# nothing\nsuper-key = 'cmd'\n")
    }

    @Test func aKeyInsideATableIsNotTheSetting() throws {
        let toml = "[mode.main.binding]\nsuper-key = 'workspace 1'\n"
        let text = try rewriteSuperKeySetting(toml, .alt).get()
        #expect(text == "super-key = 'alt'\n\n[mode.main.binding]\nsuper-key = 'workspace 1'\n")
    }
}

// MARK: Editor and Super key pane

private let editorConfig = """
    config-version = 2

    [mode.main.binding]
        alt-1 = 'workspace 1'
        alt-w = 'close' # keep me
    """

@MainActor
final class SuperKeyEditorTest {
    private let url: URL = FileManager.default.temporaryDirectory.appending(path: "super-key-\(UUID().uuidString).toml")
    private var saves = 0

    init() throws { try editorConfig.write(to: url, atomically: true, encoding: .utf8) }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak-keybindings"))
    }

    private func makeModel(_ text: String = editorConfig) throws -> KeybindingEditorModel {
        try text.write(to: url, atomically: true, encoding: .utf8)
        let model = KeybindingEditorModel(configUrlProvider: { [url] in .success(url) }, afterSave: { self.saves += 1 })
        model.load()
        return model
    }

    private var fileText: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @Test func recorderTakesOptionAsSuperOnlyWhileOptionIsSuper() throws {
        let model = try makeModel()
        let id = model.modes[0].bindings[1].id
        model.startRecording(id)
        model.record(keyCode: 11, modifierFlags: [.option])
        #expect(model.modes[0].bindings[1].key == "alt-b")

        let superOnOption = try makeModel("super-key = 'alt'\n" + editorConfig)
        let id2 = superOnOption.modes[0].bindings[1].id
        superOnOption.startRecording(id2)
        superOnOption.record(keyCode: 11, modifierFlags: [.option, .shift])
        #expect(superOnOption.modes[0].bindings[1].key == "super-shift-b")
    }

    /// While recording, the Super key tap hands its chords to the recorder instead of running bindings
    @Test func recorderTakesChordsFromTheSuperKeyTap() throws {
        let model = try makeModel()
        let id = model.modes[0].bindings[0].id
        model.startRecording(id)
        superChordPressed(SuperChord(keyCode: 11, modifiers: [.shift]))
        #expect(model.modes[0].bindings[0].key == "super-shift-b")
        #expect(model.recordingBindingId == nil)
        #expect(superChordRecorder == nil)
    }

    @Test func editorFlagsSuperAndOptionClashWhileOptionIsSuper() throws {
        let model = try makeModel("super-key = 'alt'\n" + editorConfig)
        model.modes[0].bindings[0].key = "super-w"
        let mode = model.modes[0]
        #expect(model.errors(for: mode.bindings[0], in: mode).first?.contains("also bound to 'close'") == true)
    }

    @Test func paneConvertsAndUndoes() async throws {
        let model = try makeModel()
        let pane = SuperKeyPaneModel(editor: model)
        await pane.convertOptionBindings()
        #expect(pane.status?.isError == false)
        #expect(fileText == editorConfig.replacingOccurrences(of: "alt-", with: "super-"))
        #expect(model.modes[0].bindings.map(\.key) == ["super-1", "super-w"])
        #expect(saves == 1)

        await pane.undoConversion()
        #expect(fileText == editorConfig)
        #expect(pane.converted == nil)
    }

    @Test func paneWritesTheSetting() async throws {
        let model = try makeModel()
        let pane = SuperKeyPaneModel(editor: model)
        await pane.select(.rightCmd)
        #expect(model.superKeySetting == .rightCmd)
        #expect(fileText == "config-version = 2\nsuper-key = 'right-cmd'\n" + editorConfig.dropFirst("config-version = 2\n".count))
        await pane.select(.capsLock)
        #expect(fileText.contains("super-key = 'caps-lock'"))
    }

    @Test func paneRefusesWhileBindingsHaveUnsavedEdits() async throws {
        let model = try makeModel()
        model.modes[0].bindings[0].commands = ["fullscreen"]
        let pane = SuperKeyPaneModel(editor: model)
        await pane.select(.rightCmd)
        #expect(pane.status?.isError == true)
        #expect(fileText == editorConfig)
    }
}
