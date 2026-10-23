// swift-testing rather than XCTest, so these run with the Command Line Tools alone: ./test-workspace-layouts.sh
@testable import AppBundle
import AppKit
import Common
import Foundation
import Testing

private let withoutLayouts = """
    config-version = 2
    # Possible values: tiles|accordion
    default-root-container-layout = 'tiles'
    default-root-container-orientation = 'auto'

    [gaps]
        inner.horizontal = 10

    [mode.main.binding]
        alt-1 = 'workspace 1'
        alt-shift-2 = 'move-node-to-workspace 2'

    """

private let withLayouts = """
    config-version = 2
    default-root-container-layout = 'tiles'
    default-workspace-layout = 'dwindle' # like Hyprland

    [workspace-layout]
        # Coding
        3 = 'tiles'
        1 = "floating" # chat
        web = 'tiles'

    [mode.main.binding]
        alt-1 = 'workspace 1'

    """

private let projectRoot: URL = {
    var url = URL(filePath: #filePath).absoluteURL
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    return url
}()

private func settings(_ toml: String) -> WorkspaceLayoutSettings { readWorkspaceLayoutSettings(toml).getOrDie() }

private func overrides(_ pairs: [(String, WorkspaceLayout)]) -> [WorkspaceLayoutOverride] {
    pairs.map { WorkspaceLayoutOverride(workspace: $0.0, layout: $0.1) }
}

/// Every text the rewriter hands back must also be a config AeroSpace accepts
@MainActor
private func rewrite(_ toml: String, _ edit: (inout WorkspaceLayoutSettings) -> Void) -> String {
    var desired = settings(toml)
    edit(&desired)
    let result = rewriteWorkspaceLayouts(toml, desired).getOrDie()
    #expect(parseConfig(result).errors == [])
    return result
}

@MainActor
struct EditableWorkspaceLayoutsTest {
    @Test func readsBothKeysInFileOrder() {
        #expect(settings(withLayouts) == WorkspaceLayoutSettings(
            defaultLayout: .dwindle,
            overrides: overrides([("3", .tiles), ("1", .floating), ("web", .tiles)]),
        ))
    }

    @Test func readsAbsentKeys() {
        #expect(settings(withoutLayouts) == WorkspaceLayoutSettings(defaultLayout: nil, overrides: []))
        #expect(settings("") == WorkspaceLayoutSettings(defaultLayout: nil, overrides: []))
    }

    @Test(arguments: [
        "default-workspace-layout = 3",
        "default-workspace-layout = 'spiral'",
        "workspace-layout = 'tiles'",
        "[workspace-layout]\n1 = 2",
        "[workspace-layout]\n1 = 'accordion'",
        "default-workspace-layout = ",
    ])
    func readFailsOnWrongValues(toml: String) {
        #expect(!readWorkspaceLayoutSettings(toml).isSuccess)
    }

    @Test(arguments: ["default-config.toml", "i3-like-config-example.toml"])
    func unchangedRewriteIsByteIdentical(example: String) throws {
        #expect(rewrite(withLayouts) { _ in } == withLayouts)
        #expect(rewrite(withoutLayouts) { _ in } == withoutLayouts)
        let toml = try String(contentsOf: projectRoot.appending(component: "docs/config-examples/\(example)"), encoding: .utf8)
        #expect(rewrite(toml) { _ in } == toml)
    }

    @Test func setDefaultGoesRightAfterRootContainerLayout() {
        let result = rewrite(withoutLayouts) { $0.defaultLayout = .dwindle }
        #expect(result == withoutLayouts.replacingOccurrences(
            of: "default-root-container-layout = 'tiles'\n",
            with: "default-root-container-layout = 'tiles'\ndefault-workspace-layout = 'dwindle'\n",
        ))
    }

    @Test func setDefaultFallsBackToConfigVersionThenTop() {
        #expect(rewrite("config-version = 2\n[mode.main.binding]\n") { $0.defaultLayout = .floating } ==
            "config-version = 2\ndefault-workspace-layout = 'floating'\n[mode.main.binding]\n")
        #expect(rewrite("# My config\n[mode.main.binding]\n") { $0.defaultLayout = .floating } ==
            "default-workspace-layout = 'floating'\n# My config\n[mode.main.binding]\n")
    }

    @Test func changeDefaultInPlaceKeepsTrailingComment() {
        let result = rewrite(withLayouts) { $0.defaultLayout = .floating }
        #expect(result == withLayouts.replacingOccurrences(
            of: "default-workspace-layout = 'dwindle' # like Hyprland",
            with: "default-workspace-layout = 'floating' # like Hyprland",
        ))
    }

    @Test func clearDefaultDeletesItsLine() {
        let result = rewrite(withLayouts) { $0.defaultLayout = nil }
        #expect(result == withLayouts.replacingOccurrences(of: "default-workspace-layout = 'dwindle' # like Hyprland\n", with: ""))
        #expect(settings(result).defaultLayout == nil)
    }

    @Test func firstOverrideAppendsTheTable() {
        let result = rewrite(withoutLayouts) { $0.overrides = overrides([("2", .dwindle), ("dev.web", .floating)]) }
        #expect(result == withoutLayouts + "\n[workspace-layout]\n    2 = 'dwindle'\n    \"dev.web\" = 'floating'\n")
        #expect(settings(result).overrides == overrides([("2", .dwindle), ("dev.web", .floating)]))
    }

    @Test func changeOneEntryInPlace() {
        let result = rewrite(withLayouts) { $0.overrides[1].layout = .dwindle }
        #expect(result == withLayouts.replacingOccurrences(of: "1 = \"floating\" # chat", with: "1 = 'dwindle' # chat"))
    }

    @Test func deleteOneEntry() {
        let result = rewrite(withLayouts) { $0.overrides.remove(at: 1) }
        #expect(result == withLayouts.replacingOccurrences(of: "    1 = \"floating\" # chat\n", with: ""))
    }

    @Test func deleteTheLastEntryKeepsTheHeader() {
        let toml = "config-version = 2\n\n[workspace-layout]\n    1 = 'tiles'\n"
        let result = rewrite(toml) { $0.overrides = [] }
        #expect(result == "config-version = 2\n\n[workspace-layout]\n")
        #expect(settings(result).overrides == [])
    }

    @Test func addToTheTableAfterItsLastEntry() {
        let result = rewrite(withLayouts) { $0.overrides.append(WorkspaceLayoutOverride(workspace: "2", layout: .floating)) }
        #expect(result == withLayouts.replacingOccurrences(of: "    web = 'tiles'\n", with: "    web = 'tiles'\n    2 = 'floating'\n"))
    }

    @Test func inlineTableIsReadButOnlyTheDefaultCanBeRewritten() {
        let toml = "config-version = 2\nworkspace-layout = { 1 = 'tiles' }\n"
        #expect(settings(toml) == WorkspaceLayoutSettings(defaultLayout: nil, overrides: overrides([("1", .tiles)])))

        var changed = settings(toml)
        changed.overrides[0].layout = .dwindle
        let failure = rewriteWorkspaceLayouts(toml, changed).failureOrNil
        #expect(failure?.contains("Please edit the config file by hand") == true)

        var added = settings(toml)
        added.overrides.append(WorkspaceLayoutOverride(workspace: "2", layout: .floating))
        #expect(rewriteWorkspaceLayouts(toml, added).failureOrNil?.contains("Please edit the config file by hand") == true)

        #expect(rewrite(toml) { $0.defaultLayout = .dwindle } ==
            "config-version = 2\ndefault-workspace-layout = 'dwindle'\nworkspace-layout = { 1 = 'tiles' }\n")
    }

    @Test func everyEditOnTheDefaultConfigParses() throws {
        let toml = try String(contentsOf: projectRoot.appending(component: "docs/config-examples/default-config.toml"), encoding: .utf8)
        var current = toml
        let edits: [(inout WorkspaceLayoutSettings) -> Void] = [
            { $0.defaultLayout = .dwindle },
            { $0.overrides = overrides([("1", .tiles), ("B", .floating)]) },
            { $0.defaultLayout = .floating },
            { $0.overrides[0].layout = .dwindle },
            { $0.overrides.removeAll { $0.workspace == "B" } },
            { $0.defaultLayout = nil },
            { $0.overrides = [] },
        ]
        for edit in edits {
            current = rewrite(current, edit)
        }
        // Back where it started, but for the header that the last deletion keeps
        #expect(current == toml + "\n[workspace-layout]\n")
    }

    @Test func omarchyPresetsCycleTheLayout() {
        for superKey in ["alt", "cmd"] {
            let bindings = omarchyBindings(superKey: superKey)
            let index = bindings.firstIndex { $0.key == "\(superKey)-shift-t" }
            #expect(index.map { bindings[$0].command } == "workspace-layout next")
            #expect(index.map { bindings[$0 - 1].key } == "\(superKey)-t")
        }
    }

    @Test func describesWorkspaceLayoutCommands() {
        #expect(describeCommands(["workspace-layout next"]).title == "Cycle workspace layout")
        #expect(describeCommands(["workspace-layout dwindle"]).title == "Workspace layout: Dwindle")
        #expect(describeCommands(["workspace-layout --workspace 2 tiles floating"]).title == "Workspace layout: Tiles / Floating")
        #expect(describeCommands(["workspace-layout next"]).category == .windows)
    }
}

@MainActor
final class EditableWorkspaceLayoutsPaneModelTest {
    private let url: URL = FileManager.default.temporaryDirectory.appending(path: "layouts-pane-\(UUID().uuidString).toml")
    private var saves = 0

    private static let config = """
        config-version = 2
        default-workspace-layout = 'dwindle'
        persistent-workspaces = ['1', '10', '2']

        [workspace-layout]
            1 = 'tiles'

        [mode.main.binding]
            alt-1 = 'workspace 1'
            alt-w = 'workspace web'
            alt-shift-3 = 'move-node-to-workspace 3'

        """

    init() throws {
        try Self.config.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak-keybindings"))
    }

    private func makeModel() -> LayoutsPaneModel {
        let editor = KeybindingEditorModel(configUrlProvider: { [url] in .success(url) }, afterSave: { self.saves += 1 })
        let model = LayoutsPaneModel(editor: editor)
        model.load()
        return model
    }

    @Test func saveWritesLayoutsAndShortcutTogether() async throws {
        let model = makeModel()
        model.setDefault(.floating)
        #expect(model.addOverride("2") == nil)
        model.editor.modes[0].bindings.append(EditableBinding(originalKey: nil, key: "alt-shift-t", commands: [cycleWorkspaceLayoutCommand]))
        #expect(model.unsavedChangeCount == 3)
        #expect(model.canSave)

        await model.save()
        #expect(model.status?.isError == false)
        #expect(!model.isDirty)
        #expect(saves == 1, "one write, one reload")
        #expect(try String(contentsOf: url.appendingPathExtension("bak-keybindings"), encoding: .utf8) == Self.config, "the first GUI write keeps the original")
        let expected = Self.config
            .replacingOccurrences(of: "default-workspace-layout = 'dwindle'", with: "default-workspace-layout = 'floating'")
            .replacingOccurrences(of: "    1 = 'tiles'\n", with: "    1 = 'tiles'\n    2 = 'tiles'\n")
            .replacingOccurrences(
                of: "    alt-shift-3 = 'move-node-to-workspace 3'\n",
                with: "    alt-shift-3 = 'move-node-to-workspace 3'\n    alt-shift-t = 'workspace-layout next'\n",
            )
        #expect(try String(contentsOf: url, encoding: .utf8) == expected)

        // The bindings view can still save after the pane wrote the file
        model.editor.modes[0].bindings[0].commands = ["workspace 2"]
        await model.editor.save()
        #expect(model.editor.status?.isError == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == expected.replacingOccurrences(of: "alt-1 = 'workspace 1'", with: "alt-1 = 'workspace 2'"))
    }

    @Test func saveRefusesWhenTheLayoutsChangedOnDisk() async throws {
        let model = makeModel()
        model.setDefault(.tiles)
        let edited = Self.config.replacingOccurrences(of: "1 = 'tiles'", with: "1 = 'floating'")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        await model.save()
        #expect(model.status?.isError == true)
        #expect(model.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == edited)
        #expect(saves == 0)
    }

    @Test func revertDropsLayoutAndShortcutEdits() {
        let model = makeModel()
        model.setOverride("1", .floating)
        model.editor.modes[0].bindings.append(EditableBinding(originalKey: nil, key: "alt-shift-t", commands: [cycleWorkspaceLayoutCommand]))
        #expect(model.isDirty)
        model.revert()
        #expect(!model.isDirty)
        #expect(model.settings.overrides == [WorkspaceLayoutOverride(workspace: "1", layout: .tiles)])
        #expect(model.shortcutBinding == nil)
    }

    @Test func recordingAShortcutAddsTheBindingAndEscDropsIt() {
        let model = makeModel()
        model.recordShortcut()
        let id = model.shortcutBinding?.id
        #expect(id != nil)
        #expect(model.editor.recordingBindingId == id)

        model.editor.record(keyCode: 53, modifierFlags: []) // esc
        model.recordingEnded()
        #expect(model.shortcutBinding == nil)
        #expect(!model.isDirty)

        model.recordShortcut()
        model.editor.record(keyCode: 17, modifierFlags: [.option, .shift]) // "t"
        model.recordingEnded()
        #expect(model.shortcutBinding?.key == "alt-shift-t")
        #expect(model.shortcutErrors == [])
        #expect(model.unsavedChangeCount == 1)
    }

    @Test func shortcutClashIsReported() {
        let model = makeModel()
        model.recordShortcut()
        model.editor.record(keyCode: 13, modifierFlags: [.option]) // "w", already bound
        #expect(model.shortcutErrors.count == 1)
        #expect(!model.canSave)
    }

    @Test func pickingTheLayoutThatAppliesChangesNothing() {
        let model = makeModel()
        model.setDefault(.dwindle)
        #expect(!model.isDirty)
        model.setDefault(.tiles)
        model.setDefault(.dwindle)
        #expect(!model.isDirty, "going away and back is no change")
        model.setOverride("1", nil)
        #expect(model.isDirty)
        #expect(model.addOverride("1") == nil)
        #expect(model.settings.overrides == [WorkspaceLayoutOverride(workspace: "1", layout: .tiles)])
        #expect(!model.isDirty)
    }

    @Test func addOverrideCandidatesAndValidation() {
        let model = makeModel()
        #expect(model.overrideCandidates == ["2", "3", "10", "web"])
        #expect(model.addOverride("next") != nil)
        #expect(model.addOverride("1") != nil)
        #expect(model.addOverride(" 7 ") == nil)
        #expect(model.settings.overrides.last == WorkspaceLayoutOverride(workspace: "7", layout: .tiles))
        #expect(model.overrideCandidates == ["2", "3", "10", "web"])
    }
}
