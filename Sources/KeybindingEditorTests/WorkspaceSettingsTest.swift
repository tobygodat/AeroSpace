@testable import AppBundle
import Common
import Foundation
import Testing

private let upstreamMultiline = """
    # Config version for compatibility and deprecations
    # Fallback value (if you omit the key): config-version = 1
    config-version = 2

    # Start AeroSpace at login
    start-at-login = false

    # List of workspaces that should stay alive even when they contain no windows,
    # even when they are invisible.
    # This config option is only available since 'config-version = 2'
    # Fallback value (if you omit the key): persistent-workspaces = []
    persistent-workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B",
                             "C", "D", "E", "F", "G", "I", "M", "N", "O", "P", "Q",
                             "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]

    # A callback that runs every time binding mode changes
    on-mode-changed = []

    [mode.main.binding]
        alt-1 = 'workspace 1'
        alt-2 = 'workspace 2'
        alt-3 = 'workspace 3'
        alt-4 = 'workspace 4'
        alt-5 = 'workspace 5'
        alt-6 = 'workspace 6'
        alt-7 = 'workspace 7'
        alt-8 = 'workspace 8'
        alt-9 = 'workspace 9'
        alt-a = 'workspace A' # In your config, you can drop workspace bindings that you don't need

        alt-shift-1 = 'move-node-to-workspace 1'
        alt-shift-2 = 'move-node-to-workspace 2'
        alt-shift-3 = 'move-node-to-workspace 3'
        alt-shift-4 = 'move-node-to-workspace 4'
        alt-shift-5 = 'move-node-to-workspace 5'
        alt-shift-6 = 'move-node-to-workspace 6'
        alt-shift-7 = 'move-node-to-workspace 7'
        alt-shift-8 = 'move-node-to-workspace 8'
        alt-shift-9 = 'move-node-to-workspace 9'

    """

/// Omarchy-style bindings for workspaces 1-3 with `superKey` as Super
private func threeWorkspaces(superKey: String, extraBindings: String = "") -> String {
    """
    config-version = 2
    persistent-workspaces = ["1", "2", "3"]

    [mode.main.binding]
        \(superKey)-1 = 'workspace 1'
        \(superKey)-2 = 'workspace 2'
        \(superKey)-3 = 'workspace 3'
        ctrl-9 = 'workspace 9'
        \(superKey)-shift-1 = 'move-node-to-workspace --focus-follows-window 1'
        \(superKey)-shift-2 = 'move-node-to-workspace --focus-follows-window 2'
        \(superKey)-shift-3 = 'move-node-to-workspace --focus-follows-window 3'
        \(superKey)-h = 'focus left'\(extraBindings)

    """
}

private let projectRoot: URL = {
    var url = URL(filePath: #filePath).absoluteURL
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    return url
}()

private let defaultConfig = try! String(contentsOf: projectRoot.appending(component: "docs/config-examples/default-config.toml"), encoding: .utf8)

@MainActor
private func rewrite(_ toml: String, _ edit: (inout WorkspaceSettings) -> Void) -> WorkspaceSettingsRewrite {
    var settings = readWorkspaceSettings(toml)
    edit(&settings)
    return rewriteWorkspaceSettings(toml, settings).getOrDie()
}

@MainActor
struct WorkspaceSettingsTest {
    @Test func read() {
        #expect(readWorkspaceSettings(defaultConfig) == WorkspaceSettings(count: 5, barEnabled: true, appIcons: true))
        #expect(readWorkspaceSettings(upstreamMultiline).count == 9)
        #expect(readWorkspaceSettings("config-version = 2\npersistent-workspaces = [\"3\", \"1\", \"S\", \"2\"]").count == 3)
        #expect(readWorkspaceSettings("config-version = 2\npersistent-workspaces = [\"2\", \"3\"]").count == 0)
        #expect(readWorkspaceSettings("[mode.main.binding]\nalt-1 = 'workspace 1'\nalt-2 = 'workspace 2'").count == 2) // Version 1 infers them
        let table = "config-version = 2\n[workspace-bar]\nenabled = false\napp-icons = false\n"
        #expect(readWorkspaceSettings(table) == WorkspaceSettings(count: 0, barEnabled: false, appIcons: false))
    }

    @Test(arguments: [
        defaultConfig,
        upstreamMultiline,
        threeWorkspaces(superKey: "cmd"),
        "start-at-login = true\n[mode.main.binding]\nalt-1 = 'workspace 1'\n",
        "config-version = 2\nworkspace-bar = { enabled = false }\n",
    ])
    func currentSettingsLeaveTheFileAlone(toml: String) {
        #expect(rewrite(toml) { _ in } == WorkspaceSettingsRewrite(text: toml, addedHotkeys: [], notes: []))
    }

    @Test func countUpPutsNumbersBeforeOtherWorkspaces() {
        let toml = "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"3\", \"S\"] # mine\n"
        #expect(rewrite(toml) { $0.count = 5 }.text == "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"3\", \"4\", \"5\", \"S\"] # mine\n")
    }

    @Test func countDownKeepsOtherWorkspaces() {
        let toml = "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"3\", \"4\", \"5\", \"S\"]\n"
        #expect(rewrite(toml) { $0.count = 3 }.text == "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"3\", \"S\"]\n")
    }

    @Test func multilineListBecomesOneLineAndNoBindingIsRemoved() {
        let result = rewrite(upstreamMultiline) { $0.count = 5 }
        let expected = upstreamMultiline.replacingOccurrences(
            of: """
                persistent-workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B",
                                         "C", "D", "E", "F", "G", "I", "M", "N", "O", "P", "Q",
                                         "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]
                """,
            with: #"persistent-workspaces = ["1", "2", "3", "4", "5", "A", "B", "C", "D", "E", "F", "G", "I", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]"#,
        )
        #expect(result == WorkspaceSettingsRewrite(text: expected, addedHotkeys: [], notes: []))
    }

    @Test func versionOneWithoutVersionKeyGetsVersionTwoOnTop() {
        let toml = """
            # My config
            start-at-login = true

            [mode.main.binding]
                alt-1 = 'workspace 1'
                alt-2 = 'workspace 2'
                alt-s = 'workspace S'
                alt-shift-1 = 'move-node-to-workspace 1'
                alt-shift-2 = 'move-node-to-workspace 2'

            """
        let result = rewrite(toml) { $0.count = 3 }
        #expect(result.text == """
            config-version = 2
            persistent-workspaces = ["1", "2", "3"]

            # My config
            start-at-login = true

            [mode.main.binding]
                alt-1 = 'workspace 1'
                alt-2 = 'workspace 2'
                alt-s = 'workspace S'
                alt-shift-1 = 'move-node-to-workspace 1'
                alt-shift-2 = 'move-node-to-workspace 2'
                alt-3 = 'workspace 3'
                alt-shift-3 = 'move-node-to-workspace 3'

            """)
        #expect(result.addedHotkeys == ["alt-3", "alt-shift-3"])
        #expect(result.notes.contains { $0.contains("config-version = 2") })
    }

    @Test func versionOneKeyIsBumpedInPlace() {
        let toml = "config-version = 1 # old\n[mode.main.binding]\nalt-1 = 'workspace 1'\nalt-shift-1 = 'move-node-to-workspace 1'\n"
        let result = rewrite(toml) { $0.count = 2 }
        #expect(result.text == """
            config-version = 2 # old
            persistent-workspaces = ["1", "2"]
            [mode.main.binding]
            alt-1 = 'workspace 1'
            alt-shift-1 = 'move-node-to-workspace 1'
            alt-2 = 'workspace 2'
            alt-shift-2 = 'move-node-to-workspace 2'

            """)
        #expect(result.notes.contains { $0.contains("config-version = 2") })
    }

    @Test func missingListIsInsertedAfterConfigVersion() {
        let result = rewrite("config-version = 2\nstart-at-login = true\n") { $0.count = 3 }
        #expect(result.text == "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"3\"]\nstart-at-login = true\n")
        #expect(result.addedHotkeys == [])
        #expect(result.notes == ["No Super+number hotkeys to copy, so none were added. Add them in Keybindings"])
    }

    @Test func barKeysInDottedFormKeepTheirComment() {
        let toml = "config-version = 2\npersistent-workspaces = [\"1\"]\nworkspace-bar.app-icons = true # icons next to numbers\n\n[mode.main.binding]\n"
        let result = rewrite(toml) {
            $0.barEnabled = false
            $0.appIcons = false
        }
        #expect(result.text == """
            config-version = 2
            persistent-workspaces = ["1"]
            workspace-bar.app-icons = false # icons next to numbers
            workspace-bar.enabled = false

            [mode.main.binding]

            """)
    }

    @Test func barKeysInTableForm() {
        let toml = """
            config-version = 2

            [workspace-bar]
                enabled = true # show it

            [mode.main.binding]
                alt-1 = 'workspace 1'

            """
        let result = rewrite(toml) {
            $0.barEnabled = false
            $0.appIcons = false
        }
        #expect(result.text == toml.replacingOccurrences(of: "    enabled = true # show it\n", with: "    enabled = false # show it\n    app-icons = false\n"))
    }

    @Test func missingBarKeyGoesAfterTheList() {
        let toml = "config-version = 2\npersistent-workspaces = [\"1\", \"2\"]\nstart-at-login = true\n"
        #expect(rewrite(toml) { $0.barEnabled = false }.text == """
            config-version = 2
            persistent-workspaces = ["1", "2"]
            workspace-bar.enabled = false
            start-at-login = true

            """)
    }

    @Test func defaultConfigRoundTrip() {
        let result = rewrite(defaultConfig) {
            $0.count = 7
            $0.appIcons = false
        }
        let expected = defaultConfig
            .replacingOccurrences(of: #"persistent-workspaces = ["1", "2", "3", "4", "5"]"#, with: #"persistent-workspaces = ["1", "2", "3", "4", "5", "6", "7"]"#)
            .replacingOccurrences(of: "\nworkspace-bar.app-icons = true\n", with: "\nworkspace-bar.app-icons = false\n")
        #expect(result == WorkspaceSettingsRewrite(text: expected, addedHotkeys: [], notes: []))
        #expect(readWorkspaceSettings(result.text) == WorkspaceSettings(count: 7, barEnabled: true, appIcons: false))
    }

    @Test(arguments: ["alt", "cmd", "ctrl-alt"])
    func hotkeysCopyTheSuperKeyAndFlagsOfExistingBindings(superKey: String) {
        let result = rewrite(threeWorkspaces(superKey: superKey)) { $0.count = 5 }
        let expected = threeWorkspaces(
            superKey: superKey,
            extraBindings: """

                    \(superKey)-4 = 'workspace 4'
                    \(superKey)-5 = 'workspace 5'
                    \(superKey)-shift-4 = 'move-node-to-workspace --focus-follows-window 4'
                    \(superKey)-shift-5 = 'move-node-to-workspace --focus-follows-window 5'
                """,
        ).replacingOccurrences(of: #"["1", "2", "3"]"#, with: #"["1", "2", "3", "4", "5"]"#)
        #expect(result.text == expected)
        #expect(result.addedHotkeys == ["4", "5", "shift-4", "shift-5"].map { "\(superKey)-\($0)" })
        #expect(result.notes == [])
    }

    @Test func takenKeyIsSkippedWithANote() {
        let toml = threeWorkspaces(superKey: "cmd", extraBindings: "\n    cmd-5 = 'close'")
        let result = rewrite(toml) { $0.count = 5 }
        #expect(result.addedHotkeys == ["cmd-4", "cmd-shift-4", "cmd-shift-5"])
        #expect(result.notes.count == 1)
        #expect(result.notes.first?.contains(prettyShortcut("cmd-5")) == true)
        let bindings = readEditableModes(result.text).getOrDie()[0].bindings
        #expect(bindings.count == readEditableModes(toml).getOrDie()[0].bindings.count + 3)
        #expect(bindings.first { $0.key == "cmd-5" }?.commands == ["close"])
    }

    @Test func countDownRemovesNoBindings() {
        let toml = threeWorkspaces(superKey: "alt")
        let result = rewrite(toml) { $0.count = 1 }
        #expect(result == WorkspaceSettingsRewrite(
            text: toml.replacingOccurrences(of: #"["1", "2", "3"]"#, with: #"["1"]"#),
            addedHotkeys: [],
            notes: [],
        ))
    }

    @Test func versionOneMigrationDropsInferredLetterWorkspaces() {
        let upstreamVersionOne = defaultConfig
            .replacingOccurrences(of: "config-version = 2", with: "config-version = 1")
            .replacingOccurrences(of: #"persistent-workspaces = ["1", "2", "3", "4", "5"]"#, with: "")
        #expect(readWorkspaceSettings(upstreamVersionOne).count == 9)
        let result = rewrite(upstreamVersionOne) { $0.count = 5 }
        let config = parseConfig(result.text).config
        #expect(Array(config.persistentWorkspaces) == ["1", "2", "3", "4", "5"])
        #expect(readWorkspaceSettings(result.text) == WorkspaceSettings(count: 5, barEnabled: true, appIcons: true))
    }

    @Test func aGapInTheNumbersEndsTheCount() {
        let toml = "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"4\"]\n"
        #expect(readWorkspaceSettings(toml) == WorkspaceSettings(count: 2, barEnabled: true, appIcons: true))
        let result = rewrite(toml) { $0.count = 3 }
        #expect(result.text == "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"3\"]\n")
        #expect(readWorkspaceSettings(result.text).count == 3)
    }

    @Test func removingOtherWorkspacesKeepsTheNumbers() {
        let toml = "config-version = 2\npersistent-workspaces = [\"1\", \"2\", \"S\", \"Web\"]\n"
        #expect(readWorkspaceSettings(toml).otherPersistent == ["S", "Web"])
        #expect(rewrite(toml) { $0.otherPersistent = [] }.text == "config-version = 2\npersistent-workspaces = [\"1\", \"2\"]\n")
    }

    @Test func refusesToFlattenAListWithCommentsInside() {
        let toml = """
            config-version = 2
            persistent-workspaces = [
                "1", "2", "3",
                # Chat
                "C",
            ]

            """
        var settings = readWorkspaceSettings(toml)
        settings.count = 4
        #expect(!rewriteWorkspaceSettings(toml, settings).isSuccess)
        let barOnly = rewrite(toml) { $0.appIcons = false }.text
        #expect(barOnly.contains("\n    # Chat\n"))
        #expect(readWorkspaceSettings(barOnly) == WorkspaceSettings(count: 3, otherPersistent: ["C"], barEnabled: true, appIcons: false))
    }

    @Test func defaultConfigHasSuperNumberHotkeysForEveryPersistentWorkspace() {
        let main = readEditableModes(defaultConfig).getOrDie().first { $0.name == mainModeId }!
        for n in 1 ... readWorkspaceSettings(defaultConfig).count {
            #expect(main.bindings.contains { $0.normalizedCommands == ["workspace \(n)"] })
            #expect(main.bindings.contains { $0.normalizedCommands == ["move-node-to-workspace \(n)"] })
        }
    }

    @Test(arguments: ["alt", "cmd"])
    func omarchyPresetHasSuperNumberHotkeys(superKey: String) {
        let bindings = Dictionary(omarchyBindings(superKey: superKey).map { ($0.key, $0.command) }, uniquingKeysWith: { a, _ in a })
        for n in 1 ... 9 {
            #expect(bindings["\(superKey)-\(n)"] == "workspace \(n)")
            #expect(bindings["\(superKey)-shift-\(n)"] == "move-node-to-workspace --focus-follows-window \(n)")
        }
    }

    @Test func refusesAnInlineTable() {
        let toml = "config-version = 2\nworkspace-bar = { enabled = true }\n"
        #expect(!rewriteWorkspaceSettings(toml, WorkspaceSettings(count: 0, barEnabled: false, appIcons: true)).isSuccess)
    }
}

@MainActor
final class WorkspacesPaneModelTest {
    private let url: URL = FileManager.default.temporaryDirectory.appending(path: "workspaces-pane-\(UUID().uuidString).toml")
    private let original = threeWorkspaces(superKey: "cmd")
    private var saves = 0
    private var editorToDirty: KeybindingEditorModel? = nil

    init() throws {
        try original.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak-keybindings"))
    }

    private func makePane(afterSave: @escaping @MainActor () async -> Void = {}) -> (WorkspacesPaneModel, KeybindingEditorModel) {
        let editor = KeybindingEditorModel(configUrlProvider: { [url] in .success(url) }, afterSave: {
            self.saves += 1
            await afterSave()
        })
        editor.load()
        let pane = WorkspacesPaneModel(editor: editor)
        pane.load()
        return (pane, editor)
    }

    private func fileText() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func changeWritesBacksUpAndReloads() async throws {
        let (pane, editor) = makePane()
        #expect(pane.settings == WorkspaceSettings(count: 3, barEnabled: true, appIcons: true))
        await pane.change { $0.count = 4 }
        #expect(try fileText() == rewriteWorkspaceSettings(original, WorkspaceSettings(count: 4, barEnabled: true, appIcons: true)).getOrDie().text)
        #expect(try String(contentsOf: url.appendingPathExtension("bak-keybindings"), encoding: .utf8) == original)
        #expect(saves == 1)
        #expect(pane.status?.isError == false)
        #expect(pane.status?.text.contains(prettyShortcut("cmd-4")) == true)
        #expect(editor.modes[0].bindings.contains { $0.key == "cmd-4" })

        await pane.change { $0.barEnabled = false }
        #expect(readWorkspaceSettings(try fileText()) == WorkspaceSettings(count: 4, barEnabled: false, appIcons: true))
        #expect(try String(contentsOf: url.appendingPathExtension("bak-keybindings"), encoding: .utf8) == original)
    }

    @Test func keepsHandEditsMadeWhileThePaneIsOpen() async throws {
        let (pane, _) = makePane()
        let handEdited = original
            .replacingOccurrences(of: #"["1", "2", "3"]"#, with: #"["1", "2", "3", "S"]"#)
            .replacingOccurrences(of: "config-version = 2\n", with: "config-version = 2\nworkspace-bar.app-icons = false\n")
        try handEdited.write(to: url, atomically: true, encoding: .utf8)
        await pane.change { $0.barEnabled = false }
        #expect(readWorkspaceSettings(try fileText()) == WorkspaceSettings(count: 3, otherPersistent: ["S"], barEnabled: false, appIcons: false))
        #expect(pane.settings == WorkspaceSettings(count: 3, otherPersistent: ["S"], barEnabled: false, appIcons: false))
    }

    @Test func aStalePaneDoesNotUndoANewerOne() async throws {
        let (stale, editor) = makePane(afterSave: { try? await Task.sleep(for: .milliseconds(30)) })
        let fresh = WorkspacesPaneModel(editor: editor)
        fresh.load()
        let edits = [
            Task.startUnstructured { await stale.change { $0.count = 4 } },
            Task.startUnstructured { await fresh.change { $0.appIcons = false } },
            Task.startUnstructured { await stale.change { $0.count = 5 } },
        ]
        for edit in edits { await edit.value }
        #expect(readWorkspaceSettings(try fileText()) == WorkspaceSettings(count: 5, barEnabled: true, appIcons: false))
        #expect(saves == 3)
    }

    @Test func refusesWhileBindingsAreUnsaved() async throws {
        let (pane, editor) = makePane()
        editor.modes[0].bindings[0].commands = ["close"]
        await pane.change { $0.count = 5 }
        #expect(try fileText() == original)
        #expect(pane.settings?.count == 3)
        #expect(pane.status?.isError == true)
        #expect(saves == 0)
    }

    @Test func aQueuedChangeIsRefusedWhenBindingsBecomeUnsavedFirst() async throws {
        let (pane, editor) = makePane(afterSave: { self.editorToDirty?.modes[0].bindings[0].commands = ["close"] })
        editorToDirty = editor
        let edits = [
            Task.startUnstructured { await pane.change { $0.count = 4 } },
            Task.startUnstructured { await pane.change { $0.count = 5 } },
        ]
        for edit in edits { await edit.value }
        #expect(readWorkspaceSettings(try fileText()).count == 4)
        #expect(pane.settings?.count == 4)
        #expect(pane.status?.isError == true)
        #expect(saves == 1)
    }

    @Test func rapidChangesEndInTheLastOne() async throws {
        let (pane, _) = makePane(afterSave: { try? await Task.sleep(for: .milliseconds(30)) })
        let clicks = (4 ... 9).map { count in
            Task.startUnstructured { await pane.change { $0.count = count } }
        }
        for click in clicks { await click.value }
        let text = try fileText()
        #expect(readWorkspaceSettings(text).count == 9)
        #expect(pane.settings?.count == 9)
        let bindings = readEditableModes(text).getOrDie()[0].bindings
        for n in 1 ... 9 {
            #expect(bindings.filter { $0.key == "cmd-\(n)" }.map(\.commands) == [["workspace \(n)"]])
            #expect(bindings.filter { $0.key == "cmd-shift-\(n)" }.map(\.commands) == [["move-node-to-workspace --focus-follows-window \(n)"]])
        }
        #expect(bindings.filter { $0.key == "ctrl-9" }.map(\.commands) == [["workspace 9"]])
    }
}
