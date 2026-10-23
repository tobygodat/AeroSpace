import AppKit
import Carbon
import Common
import HotKey

/// A row of the Apps pane. The config is the source of truth: the shortcut is a main-mode binding that runs exactly one
/// `focus-app` command, and the home workspace is a `HomeWorkspaceRule`. An app with a home workspace but no
/// shortcut still gets a row
struct AppShortcut: Identifiable, Equatable {
    let id: UUID
    let target: FocusAppTarget
    let binding: EditableBinding?
    let home: HomeWorkspaceRule?
}

extension KeybindingEditorModel {
    var mainMode: EditableMode? { modes.first { $0.name == mainModeId } }

    var appShortcuts: [AppShortcut] {
        var rows: [AppShortcut] = []
        var appIdsWithRow: Set<String> = []
        for binding in mainMode?.bindings ?? [] {
            guard let target = focusAppTarget(of: binding) else { continue }
            let appId = AppCatalog.shared.resolve(target)?.bundleId
            rows.append(AppShortcut(id: binding.id, target: target, binding: binding, home: homeRules.first { $0.appId == appId }))
            if let appId { appIdsWithRow.insert(appId) }
        }
        for rule in homeRules where !appIdsWithRow.contains(rule.appId) {
            rows.append(AppShortcut(id: rule.id, target: .app(rule.appId), binding: nil, home: rule))
        }
        return rows
    }

    /// Adds a shortcut and starts recording its keys
    func addAppShortcut(_ target: FocusAppTarget) {
        guard let modeIndex = modes.firstIndex(where: { $0.name == mainModeId }) else { return }
        let binding = EditableBinding(originalKey: nil, key: "", commands: [target.focusAppCommand])
        modes[modeIndex].bindings.append(binding)
        startRecording(binding.id)
    }

    /// Adds a suggested shortcut. A binding that already uses the keys is changed in place, so its line stays where it is
    func addSuggestion(_ suggestion: AppShortcutSuggestion) {
        guard let modeIndex = modes.firstIndex(where: { $0.name == mainModeId }) else { return }
        if let index = modes[modeIndex].bindings.firstIndex(where: { $0.key == suggestion.key }) {
            modes[modeIndex].bindings[index].commands = [suggestion.target.focusAppCommand]
        } else {
            modes[modeIndex].bindings.append(EditableBinding(originalKey: nil, key: suggestion.key, commands: [suggestion.target.focusAppCommand]))
        }
    }

    func setTarget(_ target: FocusAppTarget, of row: AppShortcut) {
        let newAppId = AppCatalog.shared.resolve(target)?.bundleId
        if let home = row.home, let index = homeRules.firstIndex(where: { $0.id == home.id }) {
            if let newAppId, !homeRules.contains(where: { $0.appId == newAppId && $0.id != home.id }) {
                homeRules[index].appId = newAppId
            } else {
                homeRules.remove(at: index)
            }
        }
        if let binding = row.binding {
            updateBinding(binding.id) { $0.commands = [target.focusAppCommand] }
        }
    }

    /// nil removes the home workspace
    func setHome(_ workspace: String?, of row: AppShortcut) {
        if let home = row.home, let index = homeRules.firstIndex(where: { $0.id == home.id }) {
            if let workspace { homeRules[index].workspace = workspace } else { homeRules.remove(at: index) }
        } else if let workspace, let appId = AppCatalog.shared.resolve(row.target)?.bundleId {
            homeRules.append(HomeWorkspaceRule(originalAppId: nil, appId: appId, workspace: workspace))
        }
    }

    func removeAppShortcut(_ row: AppShortcut) {
        if let binding = row.binding { deleteBinding(binding.id) }
        if let home = row.home { homeRules.removeAll { $0.id == home.id } }
    }

    /// Rows without a shortcut get a binding first
    func recordShortcut(of row: AppShortcut) {
        if let binding = row.binding {
            toggleRecording(binding.id)
        } else {
            addAppShortcut(row.target)
        }
    }

    /// Workspaces the home picker offers: 1-9 and every other workspace the config names
    var knownWorkspaceNames: [String] {
        var names = (1 ... 9).map(String.init)
        let fromBindings = mainMode?.bindings.flatMap(\.normalizedCommands).compactMap { command -> String? in
            let words = command.split(separator: " ").map(String.init)
            return words.first == "workspace" || words.first == "move-node-to-workspace" ? words.last : nil
        } ?? []
        for name in fromBindings + homeRules.map(\.workspace)
            where isPlainWorkspaceName(name) && !["next", "prev"].contains(name) && !names.contains(name)
        {
            names.append(name)
        }
        return names
    }

    /// The modifiers of the main-mode binding for "workspace 1", which is how the Omarchy presets place Super
    var superKey: String {
        guard let key = mainMode?.bindings.first(where: { $0.normalizedCommands == ["workspace 1"] })?.key,
              key.hasSuffix("-1") else { return "alt" }
        return String(key.dropLast(2))
    }

    /// Omarchy's app shortcuts for the configured Super key that aren't in the config yet. When the keys already open an
    /// app (Super+B opening Chrome), the suggestion goes to that app rather than the default one
    var appShortcutSuggestions: [AppShortcutSuggestion] {
        let rows = appShortcuts
        var takenAppIds = Set(rows.compactMap { AppCatalog.shared.resolve($0.target)?.bundleId })
        var takenTargets = Set(rows.map(\.target))
        return omarchyAppShortcuts(superKey: superKey).compactMap { key, command in
            let existing = mainMode?.bindings.first { $0.key == key }
            if let existing, focusAppTarget(of: existing) != nil { return nil }
            let opened = existing.flatMap { appOpened(by: $0.normalizedCommands) }.flatMap { AppCatalog.shared.resolve(.app($0)) }
            guard let target = opened.map({ FocusAppTarget.app($0.bundleId) }) ?? parseFocusAppTarget(command) else { return nil }
            let appId = AppCatalog.shared.resolve(target)?.bundleId
            guard !takenTargets.contains(target), !takenAppIds.contains(appId ?? "") else { return nil }
            takenTargets.insert(target)
            if let appId { takenAppIds.insert(appId) }
            return AppShortcutSuggestion(key: key, superKey: superKey, target: target, replaces: existing.map { describeCommands($0.normalizedCommands).title })
        }
    }

    /// "⌥B types ∫ in text fields": shown only while Option is the Super key, where most app shortcuts end up as ⌥+letter
    func optionCharacterNote(for binding: EditableBinding) -> String? {
        guard superKey == "alt",
              case .success(let (modifiers, key)) = parseBinding(binding.key, .emptyRoot, keyMapping),
              modifiers == .option || modifiers == [.option, .shift],
              let character = typedCharacter(keyCode: UInt16(key.carbonKeyCode), shift: modifiers.contains(.shift))
        else { return nil }
        return "\(prettyShortcut(binding.key)) normally types \(character). This shortcut takes it over."
    }

    private func updateBinding(_ id: UUID, _ change: (inout EditableBinding) -> Void) {
        for modeIndex in modes.indices {
            if let index = modes[modeIndex].bindings.firstIndex(where: { $0.id == id }) {
                change(&modes[modeIndex].bindings[index])
            }
        }
    }
}

struct AppShortcutSuggestion: Identifiable, Equatable {
    let key: String
    let superKey: String
    let target: FocusAppTarget
    /// What the keys do now, when they're already bound
    let replaces: String?

    var id: String { key }

    /// The keys after Super, e.g. "shift-m"
    var keysAfterSuper: String { key.hasPrefix(superKey + "-") ? String(key.dropFirst(superKey.count + 1)) : key }
}

func focusAppTarget(of binding: EditableBinding) -> FocusAppTarget? {
    guard let command = binding.normalizedCommands.singleOrNil() else { return nil }
    return parseFocusAppTarget(command)
}

/// What the key types with Option held, in the current keyboard layout. nil for keys that type nothing visible
private func typedCharacter(keyCode: UInt16, shift: Bool) -> String? {
    guard let source = unsafe TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let layoutData = unsafe TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = unsafe Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
    var deadKeyState: UInt32 = 0
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    let modifiers = UInt32((optionKey | (shift ? shiftKey : 0)) >> 8) & 0xFF
    let status = unsafe data.withUnsafeBytes { raw -> OSStatus in
        guard let layout = unsafe raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
        return unsafe UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars,
        )
    }
    guard status == noErr, length > 0 else { return nil }
    let string = String(decoding: chars.prefix(length), as: UTF16.self)
    let isVisible = string.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && $0.properties.generalCategory != .control }
    return isVisible ? string : nil
}

// MARK: - Installed apps

/// Installed and running apps, for the app picker, row icons and resolving app ids. Lookups are cached until `refresh()`
@MainActor
final class AppCatalog: ObservableObject {
    static let shared = AppCatalog()

    struct App: Identifiable, Hashable {
        let bundleId: String
        let name: String
        let url: URL
        var id: String { bundleId }
    }

    @Published private(set) var installed: [App] = []
    private var resolved: [FocusAppTarget: App?] = [:]
    private var icons: [URL: NSImage] = [:]

    func refresh() {
        resolved = [:]
        var seen: Set<String> = []
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleURL)
        installed = (installedAppUrls() + running).compactMap(app(at:))
            .filter { seen.insert($0.bundleId).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func resolve(_ target: FocusAppTarget) -> App? {
        if let cached = resolved[target] { return cached }
        let app = resolveFocusAppTarget(target).flatMap { app(at: $0.url) }
        resolved[target] = app
        return app
    }

    func icon(_ app: App?) -> NSImage {
        guard let url = app?.url else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        if let icon = icons[url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }

    private func app(at url: URL) -> App? {
        guard let bundleId = Bundle(url: url)?.bundleIdentifier else { return nil }
        return App(bundleId: bundleId, name: url.deletingPathExtension().lastPathComponent, url: url)
    }
}
