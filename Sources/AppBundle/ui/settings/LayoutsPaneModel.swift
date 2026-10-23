import AppKit
import Common

let cycleWorkspaceLayoutCommand = "workspace-layout next"

/// State of the Layouts settings pane. The layout keys are its own. The cycle shortcut is a binding of `editor`, so one
/// Save writes both
@MainActor
final class LayoutsPaneModel: ObservableObject {
    let editor: KeybindingEditorModel
    @Published var settings = WorkspaceLayoutSettings(defaultLayout: nil, overrides: []) {
        didSet { if settings != oldValue { status = nil } }
    }
    @Published private(set) var savedSettings = WorkspaceLayoutSettings(defaultLayout: nil, overrides: [])
    @Published private(set) var loadError: String? = nil
    @Published var status: (text: String, isError: Bool)? = nil
    private var persistentWorkspaces: [String] = []

    init(editor: KeybindingEditorModel) {
        self.editor = editor
    }

    private static var instances: [ObjectIdentifier: LayoutsPaneModel] = [:]

    /// One model per editor, so unsaved edits survive switching to the bindings and back
    static func forEditor(_ editor: KeybindingEditorModel) -> LayoutsPaneModel {
        if let model = instances[ObjectIdentifier(editor)] { return model }
        let model = LayoutsPaneModel(editor: editor)
        instances[ObjectIdentifier(editor)] = model
        return model
    }

    /// Order-insensitive, like the file: re-adding a removed override is no change
    private var layoutsChanged: Bool {
        settings.defaultLayout != savedSettings.defaultLayout || settings.overridesByWorkspace != savedSettings.overridesByWorkspace
    }

    var isDirty: Bool { layoutsChanged || editor.isDirty }

    /// Changed layout keys plus the editor's changed bindings, which Save writes too
    var unsavedChangeCount: Int {
        let before = savedSettings.overridesByWorkspace
        let after = settings.overridesByWorkspace
        let changedOverrides = Set(before.keys).union(after.keys).count { before[$0] != after[$0] }
        return (settings.defaultLayout != savedSettings.defaultLayout ? 1 : 0) + changedOverrides + editor.unsavedChangeCount
    }

    /// The editor refuses to save bindings with errors, and its save runs first
    var canSave: Bool { isDirty && !(editor.isDirty && editor.hasErrors) }

    /// The first main-mode binding that only cycles the layout
    var shortcutBinding: EditableBinding? {
        editor.modes.first { $0.name == mainModeId }?.bindings.first { $0.normalizedCommands == [cycleWorkspaceLayoutCommand] }
    }

    var shortcutErrors: [String] {
        guard let binding = shortcutBinding, editor.recordingBindingId != binding.id,
              let mode = editor.modes.first(where: { $0.name == mainModeId })
        else { return [] }
        return editor.errors(for: binding, in: mode)
    }

    /// What "Add override" offers: persistent workspaces and the workspaces bindings switch or move to, minus overridden ones
    var overrideCandidates: [String] {
        let fromBindings = editor.modes.flatMap(\.bindings).flatMap(\.normalizedCommands).flatMap { raw -> [String] in
            let commands = parseCommand(raw, allowExecAndForget: true, allowEval: false).cmdOrNil?.flatten() ?? []
            return commands.filterIsInstance(of: WorkspaceCommand.self).compactMap { $0.args.target.val.workspaceNameOrNil()?.raw } +
                commands.filterIsInstance(of: MoveNodeToWorkspaceCommand.self).compactMap { $0.args.target.val.workspaceNameOrNil()?.raw }
        }
        let overridden = Set(settings.overrides.map(\.workspace))
        return Set(persistentWorkspaces + fromBindings)
            .filter { !overridden.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Loading

    func load() {
        editor.loadIfClean()
        readConfig()
    }

    /// Re-reads the config unless there are unsaved layout edits
    func loadIfClean() {
        if layoutsChanged {
            editor.loadIfClean()
        } else {
            load()
        }
    }

    /// Drops every unsaved edit, the editor's included, like the bindings' Reload
    func reload() {
        editor.load()
        readConfig()
    }

    private func readConfig() {
        status = nil
        guard let url = editor.configFileUrl else {
            loadError = editor.loadError ?? "Can't find the config file"
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "Can't read \(url.path)"
            return
        }
        switch readWorkspaceLayoutSettings(text) {
            case .failure(let msg):
                loadError = msg
            case .success(let loaded):
                loadError = nil
                settings = loaded
                savedSettings = loaded
                persistentWorkspaces = Array(parseConfig(text).config.persistentWorkspaces)
        }
    }

    // MARK: Editing

    func revert() {
        editor.revert()
        settings = savedSettings
        status = nil
    }

    /// Picking the saved layout keeps an absent key absent, so switching away and back again is no change
    func setDefault(_ layout: WorkspaceLayout) {
        settings.defaultLayout = layout == savedSettings.effectiveDefault ? savedSettings.defaultLayout : layout
    }

    /// nil removes the override ("Same as default")
    func setOverride(_ workspace: String, _ layout: WorkspaceLayout?) {
        guard let index = settings.overrides.firstIndex(where: { $0.workspace == workspace }) else { return }
        if let layout {
            settings.overrides[index].layout = layout
        } else {
            settings.overrides.remove(at: index)
        }
    }

    /// Adds an override with a layout other than the default, for the user to adjust. Returns why the name can't be used
    func addOverride(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if case .failure(let msg) = WorkspaceName.parse(name) { return msg }
        if settings.overrides.contains(where: { $0.workspace == name }) { return "Workspace \(name) already has an override" }
        let layout = WorkspaceLayout.allCases.first { $0 != settings.effectiveDefault } ?? .tiles
        settings.overrides.append(WorkspaceLayoutOverride(workspace: name, layout: layout))
        return nil
    }

    /// Records the cycle shortcut, adding a main-mode binding for it when there is none
    func recordShortcut() {
        status = nil
        if let binding = shortcutBinding {
            editor.toggleRecording(binding.id)
            return
        }
        let binding = EditableBinding(originalKey: nil, key: "", commands: [cycleWorkspaceLayoutCommand])
        if let index = editor.modes.firstIndex(where: { $0.name == mainModeId }) {
            editor.modes[index].bindings.append(binding)
        } else {
            editor.modes.insert(EditableMode(name: mainModeId, bindings: [binding]), at: 0)
        }
        editor.startRecording(binding.id)
    }

    /// Esc while recording a binding that `recordShortcut` added leaves no keyless binding behind to block Save
    func recordingEnded() {
        guard editor.recordingBindingId == nil, let binding = shortcutBinding, binding.originalKey == nil, binding.key.isEmpty else { return }
        editor.deleteBinding(binding.id)
    }

    // MARK: Saving

    /// One write and one reload for the layout keys and the shortcut together: both rewrites are text to text, so
    /// they run on the same text and nothing is saved unless the whole result validates
    func save() async {
        editor.stopRecording()
        guard let url = editor.configFileUrl else { return }
        let resolvedUrl = url.resolvingSymlinksInPath() // Keep dotfile symlinks intact
        guard let text = try? String(contentsOf: resolvedUrl, encoding: .utf8) else {
            status = ("Can't read \(url.path)", true)
            return
        }
        if text != editor.loadedText || readWorkspaceLayoutSettings(text).getIgnoringErrorsOrNil() != savedSettings {
            status = ("The config file changed on disk since it was loaded. Press Reload (your edits will be lost) or Revert.", true)
            return
        }
        var newText = text
        if editor.isDirty {
            switch rewriteBindings(newText, editor.modes) {
                case .failure(let msg):
                    status = (msg, true)
                    return
                case .success(let it):
                    newText = it
            }
        }
        if layoutsChanged {
            switch rewriteWorkspaceLayouts(newText, settings) {
                case .failure(let msg):
                    status = (msg, true)
                    return
                case .success(let it):
                    newText = it
            }
        }
        let errors = parseConfig(newText).errors
        if !errors.isEmpty {
            status = (errors.map { $0.description(.error) }.joined(separator: "\n"), true)
            return
        }
        do {
            try editor.backUpConfigOnce(resolvedUrl)
            try newText.write(to: resolvedUrl, atomically: true, encoding: .utf8)
        } catch {
            status = ("Couldn't save: \(error.localizedDescription)", true)
            return
        }
        savedSettings = settings
        editor.load() // Picks up the saved bindings as the editor's new baseline
        status = ("Saved to \(url.displayPath)", false)
        await editor.afterSave()
    }
}
