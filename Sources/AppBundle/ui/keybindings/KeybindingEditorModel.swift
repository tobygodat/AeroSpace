import AppKit
import Common
import HotKey

@MainActor
final class KeybindingEditorModel: ObservableObject {
    static let shared = KeybindingEditorModel(
        configUrlProvider: keybindingEditorConfigUrl,
        afterSave: reloadConfigAfterKeybindingEdit,
    )

    @Published var modes: [EditableMode] = []
    @Published var selectedMode: String = mainModeId
    @Published var searchText: String = ""
    @Published var selectedBindingId: UUID? = nil
    @Published private(set) var recordingBindingId: UUID? = nil
    @Published private(set) var loadError: String? = nil
    @Published var status: (text: String, isError: Bool)? = nil
    @Published private(set) var savedModes: [EditableMode] = []
    @Published private(set) var configFileUrl: URL? = nil

    private var loadedText: String = ""
    private var keyMapping: [String: Key] = KeyMapping().resolve()
    private var keyMonitor: Any? = nil
    private var didBackUp: Bool = false
    private var isEditingConfig = false
    private var waitingConfigEdits: [CheckedContinuation<Void, Never>] = []
    private let configUrlProvider: @MainActor () -> Result<URL, String>
    private let afterSave: @MainActor () async -> Void

    init(configUrlProvider: @escaping @MainActor () -> Result<URL, String>, afterSave: @escaping @MainActor () async -> Void) {
        self.configUrlProvider = configUrlProvider
        self.afterSave = afterSave
    }

    var isDirty: Bool { modes != savedModes }

    /// Number of added, changed and deleted bindings since the last load or save
    var unsavedChangeCount: Int {
        let saved = savedModes.flatMap(\.bindings)
        let current = modes.flatMap(\.bindings)
        let savedById = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIds = Set(current.map(\.id))
        let changedOrAdded = current.filter { savedById[$0.id] != $0 }.count
        let deleted = saved.filter { !currentIds.contains($0.id) }.count
        return changedOrAdded + deleted
    }

    var selectedModeIndex: Int? { modes.firstIndex { $0.name == selectedMode } }

    // MARK: Loading

    /// Re-reads the config unless there are unsaved edits
    func loadIfClean() {
        if !isDirty || modes.isEmpty { load() }
    }

    func load() {
        stopRecording()
        status = nil
        switch configUrlProvider() {
            case .failure(let msg):
                loadError = msg
                return
            case .success(let url):
                configFileUrl = url
        }
        guard let url = configFileUrl, let text = try? String(contentsOf: url, encoding: .utf8) else {
            loadError = "Can't read \(configFileUrl?.path ?? "the config file")"
            return
        }
        switch readEditableModes(text) {
            case .failure(let msg):
                loadError = msg
            case .success(let loaded):
                loadError = nil
                loadedText = text
                let parsed = parseConfig(text).config
                keyMapping = parsed.keyMapping.resolve()
                superKeySetting = parsed.superKey
                modes = loaded.isEmpty ? [EditableMode(name: mainModeId, bindings: [])] : loaded
                savedModes = modes
                if !modes.contains(where: { $0.name == selectedMode }) {
                    selectedMode = modes.first?.name ?? mainModeId
                }
        }
    }

    // MARK: Editing

    func addBinding() {
        guard let modeIndex = selectedModeIndex else { return }
        let binding = EditableBinding(originalKey: nil, key: "", commands: [""])
        modes[modeIndex].bindings.append(binding)
        searchText = ""
        selectedBindingId = binding.id
        startRecording(binding.id)
    }

    func deleteBinding(_ id: UUID) {
        if recordingBindingId == id { stopRecording() }
        if selectedBindingId == id { selectedBindingId = nil }
        for index in modes.indices {
            modes[index].bindings.removeAll { $0.id == id }
        }
    }

    func revert() {
        stopRecording()
        modes = savedModes
        status = nil
    }

    /// Replaces the 'main' mode bindings with the preset. Bindings whose shortcut already exists keep their place in the file
    func apply(_ preset: KeybindingPreset) {
        stopRecording()
        guard let modeIndex = modes.firstIndex(where: { $0.name == mainModeId }) else { return }
        let existing = modes[modeIndex].bindings
        modes[modeIndex].bindings = preset.bindings.map { key, command in
            let originalKey = existing.first { $0.originalKey == key }?.originalKey
            return EditableBinding(originalKey: originalKey, key: key, commands: [command])
        }
        selectedMode = mainModeId
        searchText = ""
        status = ("Loaded \"\(preset.name)\". Review the bindings, then press Save.", false)
    }

    func matchesSearch(_ binding: EditableBinding) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty { return true }
        return binding.key.lowercased().contains(query) ||
            prettyShortcut(binding.key).lowercased().contains(query) ||
            binding.commands.contains { $0.lowercased().contains(query) }
    }

    // MARK: Validation

    /// Errors block saving
    func errors(for binding: EditableBinding, in mode: EditableMode) -> [String] {
        var result: [String] = []
        if binding.key.isEmpty {
            result.append("Click the shortcut and press the keys you want")
        } else if case .failure(let diagnostic) = parseBinding(binding.key, .emptyRoot, keyMapping) {
            result.append(diagnostic.message)
        } else if let canonical = canonicalShortcut(binding.key) {
            let clash = mode.bindings.first { $0.id != binding.id && canonicalShortcut($0.key) == canonical }
            if let clash {
                result.append("\(prettyShortcut(binding.key)) is also bound to '\(clash.normalizedCommands.joined(separator: "; "))'")
            }
        }
        let commands = binding.normalizedCommands
        if commands.isEmpty {
            result.append("Pick an action or type a command")
        }
        for command in commands {
            if case .failure(let msg) = parseCommand(command, allowExecAndForget: true, allowEval: false).toResult() {
                result.append(msg.split(separator: "\n").first.map(String.init) ?? msg)
            }
        }
        return result
    }

    /// Warnings are informational
    func warning(for binding: EditableBinding) -> String? {
        let parts = binding.key.split(separator: "-").map(String.init)
        guard let key = parts.last else { return nil }
        let modifiers = Set(parts.dropLast())
        if modifiers == ["alt"] && ["left", "right"].contains(key) {
            return "Replaces ⌥← / ⌥→ word jumping in text fields"
        }
        if modifiers == ["cmd"] && ["q", "w", "c", "v", "x", "z", "a", "s", "t", "n", "tab", "space"].contains(key) {
            return "Overrides a standard macOS shortcut (\(prettyShortcut(binding.key)))"
        }
        return nil
    }

    var hasErrors: Bool {
        modes.contains { mode in mode.bindings.contains { !errors(for: $0, in: mode).isEmpty } }
    }

    private func canonicalShortcut(_ key: String) -> String? {
        guard case .success(let (modifiers, key)) = parseBinding(key, .emptyRoot, keyMapping) else { return nil }
        let pressed = modifiers.resolvingSuper(superKeySetting)
        return pressed.isEmpty ? key.toString() : pressed.toString() + "-" + key.toString()
    }

    // MARK: Recording

    /// `super-key` of the loaded config. Shortcuts are compared and recorded as the keys it stands for
    private(set) var superKeySetting: SuperKey = Config().superKey

    func toggleRecording(_ id: UUID) {
        if recordingBindingId == id {
            stopRecording()
        } else {
            startRecording(id)
        }
    }

    func startRecording(_ id: UUID) {
        stopRecording()
        recordingBindingId = id
        setHotKeysPaused(true) // Otherwise AeroSpace itself would swallow shortcuts that are already bound
        superChordRecorder = { [weak self] chord in self?.record(keyCode: chord.keyCode, modifiers: chord.modifiers.union(.superKey)) }
        SuperKeyRuntime.shared.setRecording(true) // So Super can be recorded before any binding uses it
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.recordingBindingId != nil else { return false }
                self.record(keyCode: keyCode, modifierFlags: modifiers)
                return true
            }
            return consumed ? nil : event
        }
    }

    func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if recordingBindingId != nil {
            recordingBindingId = nil
            setHotKeysPaused(false)
            superChordRecorder = nil
            SuperKeyRuntime.shared.setRecording(false)
        }
    }

    /// A key pressed in the window. Option or Command is recorded as Super while it's the Super key
    func record(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        var modifiers = HotkeyModifiers(eventFlags: modifierFlags)
        if let standsFor = superKeySetting.standsFor, modifiers.contains(standsFor) {
            modifiers = modifiers.subtracting(standsFor).union(.superKey)
        }
        record(keyCode: keyCode, modifiers: modifiers)
    }

    private func record(keyCode: UInt16, modifiers: HotkeyModifiers) {
        guard let id = recordingBindingId else { return }
        if keyCode == 53 && modifiers.isEmpty { // Plain esc cancels
            stopRecording()
            return
        }
        guard let key = Key(carbonKeyCode: UInt32(keyCode)), let notation = keyNotation(for: key) else {
            NSSound.beep()
            return
        }
        let shortcut = modifiers.isEmpty ? notation : modifiers.toString() + "-" + notation
        for modeIndex in modes.indices {
            if let bindingIndex = modes[modeIndex].bindings.firstIndex(where: { $0.id == id }) {
                modes[modeIndex].bindings[bindingIndex].key = shortcut
            }
        }
        stopRecording()
    }

    /// The config notation for a physical key, honoring the config's key-mapping
    private func keyNotation(for key: Key) -> String? {
        let candidates = keyMapping.filter { $0.value == key }.map(\.key)
        return candidates.contains(key.toString()) ? key.toString() : candidates.min()
    }

    // MARK: Saving

    func save() async {
        stopRecording()
        guard let url = configFileUrl else { return }
        if hasErrors {
            status = ("Fix the highlighted bindings before saving.", true)
            return
        }
        let resolvedUrl = url.resolvingSymlinksInPath() // Keep dotfile symlinks intact
        guard let currentText = try? String(contentsOf: resolvedUrl, encoding: .utf8) else {
            status = ("Can't read \(url.path)", true)
            return
        }
        if currentText != loadedText {
            status = ("The config file changed on disk since it was loaded. Press Reload (your edits will be lost) or Revert.", true)
            return
        }
        let newText: String
        switch rewriteBindings(currentText, modes) {
            case .failure(let msg):
                status = (msg, true)
                return
            case .success(let it):
                newText = it
        }
        let parsed = parseConfig(newText)
        if !parsed.errors.isEmpty {
            status = (parsed.errors.map { $0.description(.error) }.joined(separator: "\n"), true)
            return
        }
        do {
            if !didBackUp {
                let backupUrl = resolvedUrl.appendingPathExtension("bak-keybindings")
                try? FileManager.default.removeItem(at: backupUrl)
                try FileManager.default.copyItem(at: resolvedUrl, to: backupUrl)
                didBackUp = true
            }
            try newText.write(to: resolvedUrl, atomically: true, encoding: .utf8)
        } catch {
            status = ("Couldn't save: \(error.localizedDescription)", true)
            return
        }

        // Pick up the new original keys, keeping row identities so the list doesn't jump
        if case .success(let written) = readEditableModes(newText) {
            modes = written.map { mode in
                let edited = modes.first { $0.name == mode.name }?.bindings ?? []
                return EditableMode(name: mode.name, bindings: mode.bindings.map { binding in
                    let id = edited.first { $0.key == binding.key }?.id ?? binding.id
                    return EditableBinding(id: id, originalKey: binding.key, key: binding.key, commands: binding.commands)
                })
            }
        }
        savedModes = modes
        loadedText = newText
        keyMapping = parsed.config.keyMapping.resolve()
        superKeySetting = parsed.config.superKey
        status = ("Saved to \(url.displayPath)", false)
        await afterSave()
    }

    // MARK: Edits from Settings panes

    /// Applies `change` to the config file as it is on disk now, writes the result, and reloads the config.
    /// Edits run one at a time in call order. Refused while bindings have unsaved edits, which the write would strand
    func editConfig(_ change: @MainActor (String) -> Result<String, String>) async -> Result<String, String> {
        if isEditingConfig {
            await withCheckedContinuation { waitingConfigEdits.append($0) }
        }
        isEditingConfig = true
        defer {
            if waitingConfigEdits.isEmpty {
                isEditingConfig = false
            } else {
                waitingConfigEdits.removeFirst().resume()
            }
        }
        if isDirty { return .failure("Save or revert your keybinding changes first") }
        if configFileUrl == nil { load() }
        guard let url = configFileUrl else { return .failure(loadError ?? "Can't find the config file") }
        let resolvedUrl = url.resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: resolvedUrl, encoding: .utf8) else { return .failure("Can't read \(url.displayPath)") }
        let newText: String
        switch change(text) {
            case .failure(let msg): return .failure(msg)
            case .success(let it): newText = it
        }
        if newText == text { return .success(text) }
        let errors = parseConfig(newText).errors
        if !errors.isEmpty { return .failure(errors.map { $0.description(.error) }.joined(separator: "\n")) }
        do {
            if !didBackUp {
                let backupUrl = resolvedUrl.appendingPathExtension("bak-keybindings")
                try? FileManager.default.removeItem(at: backupUrl)
                try FileManager.default.copyItem(at: resolvedUrl, to: backupUrl)
                didBackUp = true
            }
            try newText.write(to: resolvedUrl, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Couldn't save: \(error.localizedDescription)")
        }
        load()
        await afterSave()
        return .success(newText)
    }
}

extension URL {
    /// Path with the home directory shortened to ~
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Human-readable shortcut, e.g. "alt-shift-1" → "⌥⇧1", "super-b" → "◆B"
func prettyShortcut(_ notation: String) -> String { shortcutSymbols(notation).joined() }

/// One symbol per key, modifiers first in macOS order, e.g. "alt-shift-1" → ["⌥", "⇧", "1"]
func shortcutSymbols(_ notation: String) -> [String] {
    if notation.isEmpty { return [] }
    let parts = notation.split(separator: "-").map(String.init)
    guard let key = parts.last else { return [notation] }
    let modifiers = Set(parts.dropLast())
    let symbols = [("super", "◆"), ("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
        .filter { modifiers.contains($0.0) }
        .map(\.1)
    let keySymbols: [String: String] = [
        "enter": "↩", "tab": "⇥", "space": "Space", "esc": "⎋", "backspace": "⌫", "forwardDelete": "⌦",
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "backtick": "`", "leftSquareBracket": "[", "rightSquareBracket": "]",
        "pageUp": "⇞", "pageDown": "⇟", "home": "↖", "end": "↘",
    ]
    return symbols + [keySymbols[key] ?? (key.count == 1 ? key.uppercased() : key)]
}

@MainActor private func keybindingEditorConfigUrl() -> Result<URL, String> {
    switch findCustomConfigUrl() {
        case .file(let url):
            return .success(url)
        case .noCustomConfigExists:
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: configDotfileName)
            do {
                try FileManager.default.copyItem(at: defaultConfigUrl, to: url)
                return .success(url)
            } catch {
                return .failure("Couldn't create \(url.path): \(error.localizedDescription)")
            }
        case .ambiguousConfigError(let candidates):
            return .failure("Several configs found. Remove all but one:\n" + candidates.map(\.path).joined(separator: "\n"))
    }
}

@MainActor private func reloadConfigAfterKeybindingEdit() async {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    _ = try? await runLightSession(.menuBarButton, token) {
        await reloadConfig_nonCancellable()
    }
}
