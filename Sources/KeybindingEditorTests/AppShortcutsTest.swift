@testable import AppBundle
import AppKit
import Common
import Foundation
import Testing

private let sample = """
    config-version = 2

    [mode.main.binding]
        alt-b = 'exec-and-forget open -na "Safari"'
        alt-n = 'focus-app com.apple.Notes'
        alt-1 = 'workspace 1'

    # Finder floats
    [[on-window-detected]]
        if.app-id = 'com.apple.finder'
        run = 'layout floating'

    [[on-window-detected]]
        if.app-id = 'com.apple.Notes'
        run = 'move-node-to-workspace 4' # notes live on 4

    [[on-window-detected]]
        if.app-id = 'com.apple.TextEdit'
        if.window-title-regex-substring = 'scratch'
        run = 'move-node-to-workspace 2'

    """

private func rules(_ toml: String) -> [HomeWorkspaceRule] { readHomeWorkspaceRules(toml).getOrDie() }

private func rewrite(_ toml: String, _ edit: (inout [HomeWorkspaceRule]) -> Void) -> String {
    var rules = rules(toml)
    edit(&rules)
    return rewriteHomeWorkspaceRules(toml, rules).getOrDie()
}

@MainActor
struct HomeWorkspaceRulesTest {
    @Test func readsOnlyPlainHomeRules() {
        #expect(rules(sample).map { "\($0.appId)=\($0.workspace)" } == ["com.apple.Notes=4"])
        #expect(rules("[[on-window-detected]]\nif.app-id = 'a'\nrun = ['move-node-to-workspace 3']\n").map(\.workspace) == ["3"])
        #expect(rules("[[on-window-detected]]\nif.app-id = 'a'\nrun = 'move-node-to-workspace --focus-follows-window 3'\n").isEmpty)
        #expect(rules("[[on-window-detected]]\nif.app-id = 'a'\nrun = 'move-node-to-workspace 3'\ncheck-further-callbacks = true\n").isEmpty)
        #expect(rules("on-window-detected = [{ if.app-id = 'a', run = 'move-node-to-workspace 3' }]\n").isEmpty)
    }

    @Test func unchangedRoundTripIsByteIdentical() throws {
        #expect(rewrite(sample) { _ in } == sample)
        for example in ["default-config.toml", "i3-like-config-example.toml"] {
            let toml = try String(contentsOf: projectRoot.appending(component: "docs/config-examples/\(example)"), encoding: .utf8)
            #expect(rewrite(toml) { _ in } == toml)
        }
    }

    @Test func changeWorkspaceOnlyTouchesTheRunLine() {
        let result = rewrite(sample) { $0[0].workspace = "5" }
        #expect(result == sample.replacingOccurrences(of: "run = 'move-node-to-workspace 4' # notes live on 4", with: "run = 'move-node-to-workspace 5'"))
    }

    @Test func changeAppOnlyTouchesTheAppIdLine() {
        let result = rewrite(sample) { $0[0].appId = "com.apple.Music" }
        #expect(result == sample.replacingOccurrences(of: "if.app-id = 'com.apple.Notes'", with: "if.app-id = 'com.apple.Music'"))
    }

    @Test func addGoesAfterTheLastRule() {
        let result = rewrite(sample) { $0.append(HomeWorkspaceRule(originalAppId: nil, appId: "com.google.Chrome", workspace: "4")) }
        let added = """
                run = 'move-node-to-workspace 2'

            [[on-window-detected]]
                if.app-id = 'com.google.Chrome'
                run = 'move-node-to-workspace 4'

            """
        #expect(result == sample.replacingOccurrences(of: "    run = 'move-node-to-workspace 2'\n", with: added))
        #expect(parseConfig(result).errors == [])
    }

    @Test func addToConfigWithoutRulesAppendsAtTheEnd() {
        let toml = "config-version = 2\n\n[mode.main.binding]\n    alt-1 = 'workspace 1'\n"
        let result = rewriteHomeWorkspaceRules(toml, [HomeWorkspaceRule(originalAppId: nil, appId: "com.google.Chrome", workspace: "4")]).getOrDie()
        #expect(result == toml + "\n[[on-window-detected]]\n    if.app-id = 'com.google.Chrome'\n    run = 'move-node-to-workspace 4'\n")
        #expect(rules(result).map(\.appId) == ["com.google.Chrome"])
    }

    @Test func removeDeletesTheBlockAndLeavesOtherRulesAlone() {
        let result = rewrite(sample) { $0.removeAll() }
        let removed = """
                run = 'layout floating'

            [[on-window-detected]]
                if.app-id = 'com.apple.TextEdit'
            """
        #expect(result == sample.replacingOccurrences(
            of: "    run = 'layout floating'\n\n[[on-window-detected]]\n    if.app-id = 'com.apple.Notes'\n    run = 'move-node-to-workspace 4' # notes live on 4\n\n[[on-window-detected]]\n    if.app-id = 'com.apple.TextEdit'",
            with: removed,
        ))
        #expect(parseConfig(result).config.onWindowDetected.count == 2)
    }

    @Test func refusesWhenAnotherRuleWouldChange() {
        // A sub-table that extends the last rule: inserting a new rule before it would change what it applies to
        let toml = "[[on-window-detected]]\nrun = 'layout floating'\n[on-window-detected.if]\napp-id = 'a'\n"
        #expect(parseConfig(toml).errors == [])
        #expect(!rewriteHomeWorkspaceRules(toml, [HomeWorkspaceRule(originalAppId: nil, appId: "b", workspace: "2")]).isSuccess)
    }
}

@MainActor
final class AppShortcutsModelTest {
    private let url: URL = FileManager.default.temporaryDirectory.appending(path: "app-shortcuts-\(UUID().uuidString).toml")

    init() throws { try sample.write(to: url, atomically: true, encoding: .utf8) }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak-keybindings"))
    }

    private func makeModel() -> KeybindingEditorModel {
        let model = KeybindingEditorModel(configUrlProvider: { [url] in .success(url) }, afterSave: {})
        model.load()
        return model
    }

    private var written: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @Test func rowsComeFromFocusAppBindingsAndHomeRules() {
        let rows = makeModel().appShortcuts
        #expect(rows.map(\.target) == [.app("com.apple.Notes")])
        #expect(rows.first?.binding?.key == "alt-n")
        #expect(rows.first?.home?.workspace == "4")
    }

    @Test func setHomeAndSaveWritesARule() async {
        let model = makeModel()
        model.addSuggestion(AppShortcutSuggestion(key: "alt-shift-m", superKey: "alt", target: .app("com.apple.Music"), replaces: nil))
        let music = model.appShortcuts.first { $0.target == .app("com.apple.Music") }!
        model.setHome("5", of: music)
        #expect(model.isDirty)
        await model.save()
        #expect(model.status?.isError == false)
        #expect(!model.isDirty)
        let expected = sample
            .replacingOccurrences(of: "    alt-1 = 'workspace 1'\n", with: "    alt-1 = 'workspace 1'\n    alt-shift-m = 'focus-app com.apple.Music'\n")
            .replacingOccurrences(
                of: "    run = 'move-node-to-workspace 2'\n",
                with: "    run = 'move-node-to-workspace 2'\n\n[[on-window-detected]]\n    if.app-id = 'com.apple.Music'\n    run = 'move-node-to-workspace 5'\n",
            )
        #expect(written == expected)
        #expect(model.appShortcuts.first { $0.target == .app("com.apple.Music") }?.home?.workspace == "5")
    }

    @Test func suggestionReplacesTheBindingOnItsKeysInPlace() async {
        let model = makeModel()
        model.addSuggestion(AppShortcutSuggestion(key: "alt-b", superKey: "alt", target: .defaultBrowser, replaces: "Open Safari"))
        await model.save()
        #expect(written == sample.replacingOccurrences(of: #"alt-b = 'exec-and-forget open -na "Safari"'"#, with: "alt-b = 'focus-app --default-browser'"))
    }

    @Test func suggestionsGoToTheAppTheKeysAlreadyOpen() {
        let suggestions = makeModel().appShortcutSuggestions
        let browser = suggestions.first { $0.key == "alt-b" }
        #expect(browser?.target == .app("com.apple.Safari"))
        #expect(browser?.replaces == "Open Safari")
        #expect(suggestions.contains { $0.key == "alt-enter" && $0.target == .defaultTerminal })
        #expect(!suggestions.contains { $0.target == .app("com.apple.Notes") })
    }

    @Test func removeDropsTheBindingAndTheHomeRule() async {
        let model = makeModel()
        model.removeAppShortcut(model.appShortcuts[0])
        #expect(model.appShortcuts.isEmpty)
        await model.save()
        #expect(!written.contains("com.apple.Notes"))
        #expect(written.contains("com.apple.TextEdit"))
    }

    @Test func revertRestoresHomeRules() {
        let model = makeModel()
        model.setHome(nil, of: model.appShortcuts[0])
        #expect(model.unsavedChangeCount == 1)
        model.revert()
        #expect(!model.isDirty)
        #expect(model.appShortcuts[0].home?.workspace == "4")
    }

    @Test func superKeyFollowsTheWorkspaceBindings() {
        let model = makeModel()
        #expect(model.superKey == "alt")
        model.modes[0].bindings[2].key = "cmd-1"
        #expect(model.superKey == "cmd")
        #expect(model.appShortcutSuggestions.allSatisfy { $0.key.hasPrefix("cmd-") })
    }

    @Test func optionCharacterNoteOnlyWhileOptionIsSuper() {
        let model = makeModel()
        let altB = EditableBinding(originalKey: nil, key: "alt-b", commands: ["focus-app --default-browser"])
        #expect(model.optionCharacterNote(for: altB) != nil) // The character depends on the keyboard layout
        #expect(model.optionCharacterNote(for: EditableBinding(originalKey: nil, key: "alt-enter", commands: ["focus-app --default-terminal"])) == nil)
        #expect(model.optionCharacterNote(for: EditableBinding(originalKey: nil, key: "cmd-alt-b", commands: ["focus-app --default-browser"])) == nil)
        model.modes[0].bindings[2].key = "cmd-1"
        #expect(model.optionCharacterNote(for: altB) == nil)
    }
}

private let projectRoot: URL = {
    var url = URL(filePath: #filePath).absoluteURL
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    return url
}()
