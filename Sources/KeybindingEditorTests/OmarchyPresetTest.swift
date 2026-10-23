@testable import AppBundle
import Common
import Foundation
import Testing

/// The integration of #1–#5: the single Omarchy preset carries every branch's bindings, with no shortcut bound twice
@MainActor
final class OmarchyPresetTest {
    private let url: URL = FileManager.default.temporaryDirectory.appending(path: "omarchy-preset-\(UUID().uuidString).toml")

    init() throws {
        try "config-version = 2\n\n[mode.main.binding]\nalt-1 = 'workspace 1'\n".write(to: url, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak-keybindings"))
    }

    private func savedOmarchyBindings() async throws -> [String: String] {
        let presets = keybindingPresets()
        #expect(presets.map(\.name) == ["Omarchy"])
        let preset = try #require(presets.first)
        let model = KeybindingEditorModel(configUrlProvider: { [url] in .success(url) }, afterSave: {})
        model.load()
        model.apply(preset)
        let main = try #require(model.modes.first { $0.name == mainModeId })
        for binding in main.bindings {
            #expect(model.errors(for: binding, in: main) == [], "\(binding.key) = \(binding.commands)")
        }
        let shortcuts = main.bindings.compactMap { model.canonicalShortcut($0.key) }
        #expect(shortcuts.count == main.bindings.count)
        #expect(Set(shortcuts).count == shortcuts.count, "duplicates: \(Dictionary(grouping: shortcuts, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")

        await model.save()
        #expect(model.status?.isError == false)
        let parsed = parseConfig(try String(contentsOf: url, encoding: .utf8))
        #expect(parsed.errors == [])
        #expect(parsed.config.modes[mainModeId]?.bindings.count == main.bindings.count)
        let reloaded = KeybindingEditorModel(configUrlProvider: { [url] in .success(url) }, afterSave: {})
        reloaded.load()
        let saved = try #require(reloaded.modes.first { $0.name == mainModeId }).bindings
        return Dictionary(saved.map { ($0.key, $0.commands.joined(separator: "; ")) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func omarchyPresetHasEveryFeaturesBindingsOnce() async throws {
        let bindings = try await savedOmarchyBindings()

        // app-hotkeys (#1): focus or launch
        #expect(bindings["super-b"] == "focus-app --default-browser")
        #expect(bindings["super-enter"] == "focus-app --default-terminal")
        #expect(bindings["super-shift-m"]?.hasPrefix("focus-app ") == true)

        // layouts (#2) and scrolling (#5): one shortcut cycles every layout
        #expect(bindings["super-shift-t"] == "workspace-layout next")

        // workspace-bar (#3): Super+1..9 and Super+Shift+1..9
        for n in 1 ... 9 {
            #expect(bindings["super-\(n)"] == "workspace \(n)")
            #expect(bindings["super-shift-\(n)"] == "move-node-to-workspace --focus-follows-window \(n)")
        }

        // super-key (#4): every binding uses the Super modifier, none is a literal Option or Command
        #expect(bindings.keys.allSatisfy { $0.hasPrefix("super-") })
    }
}
