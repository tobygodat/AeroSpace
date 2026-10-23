import Common
import Foundation
import OrderedCollections

// Read and write the settings of the Workspaces pane: the persistent workspaces "1"..."count", the workspace-bar keys,
// and the main-mode hotkeys for those workspaces. Writing is a minimal text edit like editableBindings.swift.

struct WorkspaceSettings: Equatable {
    /// Persistent workspaces "1"..."count". 0 when "1" isn't persistent. The count owns the names "1"..."9"
    var count: Int
    /// Persistent workspaces besides "1"..."9", e.g. "S". Empty for config-version 1, whose list is only inferred
    var otherPersistent: [String] = []
    var barEnabled: Bool
    var appIcons: Bool

    /// The `persistent-workspaces` these settings stand for
    var persistentWorkspaces: [String] { (0 ..< count).map { String($0 + 1) } + otherPersistent }
}

private let countedNames: Set<String> = Set((1 ... 9).map(String.init))

struct WorkspaceSettingsRewrite: Equatable {
    let text: String
    /// Keys of the main-mode bindings that were added, in config notation
    let addedHotkeys: [String]
    let notes: [String]
}

@MainActor func readWorkspaceSettings(_ rawToml: String) -> WorkspaceSettings {
    WorkspaceSettings(parseConfig(rawToml).config)
}

private extension WorkspaceSettings {
    init(_ config: Config) {
        var count = 0
        while count < 9 && config.persistentWorkspaces.contains(String(count + 1)) { count += 1 }
        self.init(
            count: count,
            otherPersistent: config.configVersion < ._2 ? [] : Array(config.persistentWorkspaces.filter { !countedNames.contains($0) }),
            barEnabled: config.workspaceBar.enabled,
            appIcons: config.workspaceBar.appIcons,
        )
    }
}

@MainActor func rewriteWorkspaceSettings(_ rawToml: String, _ desired: WorkspaceSettings) -> Result<WorkspaceSettingsRewrite, String> {
    let config = parseConfig(rawToml).config
    let current = WorkspaceSettings(config)
    if desired == current { return .success(WorkspaceSettingsRewrite(text: rawToml, addedHotkeys: [], notes: [])) }

    var lines = splitLines(rawToml)
    let statements = scanTomlStatements(lines)
    let root = statements.prefix { !$0.isTable }
    func rootStatement(_ path: [String]) -> TomlStatement? { root.first { $0.keyPath == path } }
    var replacements: [(range: Range<Int>, replacement: [String])] = []
    var topInserts: [String] = []
    var insertsAfter: [Int: [String]] = [:]
    func insert(_ line: String, after statement: TomlStatement?) {
        guard let statement else {
            topInserts.append(line)
            return
        }
        let indent = String(lines[statement.lines.lowerBound].prefix { $0 == " " || $0 == "\t" })
        insertsAfter[statement.lines.upperBound, default: []].append(indent + line)
    }
    func replaceValue(of statement: TomlStatement, with value: String) {
        replacements.append((statement.lines, [replacingValue(lines, statement, with: value)]))
    }
    var notes: [String] = []

    let configVersion = rootStatement(["config-version"])
    let persistentWorkspaces = rootStatement(["persistent-workspaces"])
    let newList = desired.persistentWorkspaces
    let writesList = desired.count != current.count || desired.otherPersistent != current.otherPersistent
    if writesList {
        if let persistentWorkspaces, hasCommentInside(lines, persistentWorkspaces) {
            return .failure("persistent-workspaces has comments inside its list, so Settings won't rewrite it. Please edit the config file by hand.")
        }
        if config.configVersion < ._2 {
            if let configVersion {
                replaceValue(of: configVersion, with: "2")
            } else {
                insert("config-version = 2", after: nil)
            }
            notes.append("Set config-version = 2, which persistent-workspaces needs")
        }
        let value = "[" + newList.map(serializeWorkspaceName).joined(separator: ", ") + "]"
        if let persistentWorkspaces {
            replaceValue(of: persistentWorkspaces, with: value)
        } else {
            insert("persistent-workspaces = \(value)", after: configVersion)
        }
    }

    let barTable = statements.firstIndex { $0.tablePath == ["workspace-bar"] }
    let barKeys = [
        ("enabled", desired.barEnabled, current.barEnabled),
        ("app-icons", desired.appIcons, current.appIcons),
    ]
    for (key, want, have) in barKeys where want != have {
        let value = want ? "true" : "false"
        if let statement = rootStatement(["workspace-bar", key]) {
            replaceValue(of: statement, with: value)
        } else if let barTable {
            let entries = statements[(barTable + 1)...].prefix { !$0.isTable }
            if let entry = entries.first(where: { $0.keyPath == [key] }) {
                replaceValue(of: entry, with: value)
            } else {
                insert("\(key) = \(value)", after: entries.last ?? statements[barTable])
            }
        } else if rootStatement(["workspace-bar"]) == nil {
            let siblings = root.last { $0.keyPath?.first == "workspace-bar" }
            insert("workspace-bar.\(key) = \(value)", after: siblings ?? persistentWorkspaces ?? configVersion)
        } else {
            return .failure("workspace-bar is written in a form Settings can't update. Please edit the config file by hand.")
        }
    }

    var edits = replacements + insertsAfter.map { (range: $0.key ..< $0.key, replacement: $0.value) }
    if !topInserts.isEmpty {
        var top = statements.first?.lines.lowerBound ?? 0
        while top > 0 && lines[top - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { top -= 1 } // Keep the first statement's comment on it
        edits.append((top ..< top, topInserts + (statements.isEmpty ? [] : [""])))
    }
    // Bottom up. On the same line, the replacement goes first so an insert there lands above the replaced statement
    for edit in edits.sorted(by: { ($0.range.lowerBound, $0.range.upperBound) > ($1.range.lowerBound, $1.range.upperBound) }) {
        lines.replaceSubrange(edit.range, with: edit.replacement)
    }
    var text = lines.joined(separator: "\n")

    var addedHotkeys: [String] = []
    if desired.count > current.count {
        switch addingWorkspaceHotkeys(text, workspaces: (current.count + 1) ... desired.count) {
            case .failure(let msg):
                return .failure(msg)
            case .success(let it):
                text = it.text
                addedHotkeys = it.addedHotkeys
                notes += it.notes
        }
    }

    let written = parseConfig(text)
    if !written.errors.isEmpty {
        return .failure(written.errors.map { $0.description(.error) }.joined(separator: "\n"))
    }
    guard WorkspaceSettings(written.config) == desired,
          !writesList || Array(written.config.persistentWorkspaces) == newList
    else {
        return .failure("The workspace settings are written in a form Settings can't update. Please edit the config file by hand.")
    }
    return .success(WorkspaceSettingsRewrite(text: text, addedHotkeys: addedHotkeys, notes: notes))
}

/// Adds the switch and move hotkeys of `workspaces` that main mode lacks. Each kind copies the most common existing
/// `<mods>-<d>` binding whose first command is `<verb> [flags] <d>`, so the Super key is whatever the config already uses
private func addingWorkspaceHotkeys(_ rawToml: String, workspaces: ClosedRange<Int>) -> Result<WorkspaceSettingsRewrite, String> {
    let modes: [EditableMode]
    switch readEditableModes(rawToml) {
        case .success(let it): modes = it
        case .failure(let it): return .failure(it)
    }
    var main = modes.first { $0.name == mainModeId } ?? EditableMode(name: mainModeId, bindings: [])
    var added: [EditableBinding] = []
    var notes: [String] = []
    for verb in ["workspace", "move-node-to-workspace"] {
        let templates = main.bindings.compactMap { HotkeyTemplate($0, verb: verb) }
        guard let template = templates.max(by: { a, b in templates.count(where: { $0 == a }) < templates.count(where: { $0 == b }) }) else {
            let note = "No Super+number hotkeys to copy, so none were added. Add them in Keybindings"
            if !notes.contains(note) { notes.append(note) }
            continue
        }
        for workspace in workspaces.map(String.init) {
            let wanted = EditableBinding(originalKey: nil, key: "\(template.modifiers)-\(workspace)", commands: template.commands(for: workspace))
            guard let existing = (main.bindings + added).first(where: { sameShortcut($0.key, wanted.key) }) else {
                added.append(wanted)
                continue
            }
            if existing.normalizedCommands != wanted.commands {
                notes.append("Skipped \(prettyShortcut(wanted.key)): it's bound to '\(existing.normalizedCommands.joined(separator: "; "))'")
            }
        }
    }
    if added.isEmpty { return .success(WorkspaceSettingsRewrite(text: rawToml, addedHotkeys: [], notes: notes)) }
    main.bindings += added
    return rewriteBindings(rawToml, [main])
        .map { WorkspaceSettingsRewrite(text: $0, addedHotkeys: added.map(\.key), notes: notes) }
}

private struct HotkeyTemplate: Equatable {
    struct Command: Equatable {
        /// The command without its trailing workspace number when `numbered`
        let text: String
        let numbered: Bool
    }

    let modifiers: String
    let commands: [Command]

    /// `binding` as a template when its key is `<mods>-<d>` and its first command is `<verb> [flags] <d>`
    init?(_ binding: EditableBinding, verb: String) {
        let parts = binding.key.split(separator: "-").map(String.init)
        let commands = binding.normalizedCommands
        guard parts.count > 1, let digit = parts.last, countedNames.contains(digit),
              let first = commands.first?.split(separator: " "),
              first.count > 1, first.first == Substring(verb), first.last == Substring(digit)
        else { return nil }
        modifiers = parts.dropLast().joined(separator: "-")
        self.commands = commands.map { command in
            let words = command.split(separator: " ")
            return words.count > 1 && words.last == Substring(digit)
                ? Command(text: words.dropLast().joined(separator: " "), numbered: true)
                : Command(text: command, numbered: false)
        }
    }

    func commands(for workspace: String) -> [String] {
        commands.map { $0.numbered ? "\($0.text) \(workspace)" : $0.text }
    }
}

/// Comments inside a multi-line value would be lost by writing it back on one line
private func hasCommentInside(_ lines: [String], _ statement: TomlStatement) -> Bool {
    statement.lines.dropLast().contains { !trailingComment(lines[$0]).isEmpty || lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#") }
}

private func sameShortcut(_ a: String, _ b: String) -> Bool {
    func canonical(_ key: String) -> [Substring] {
        let parts = key.split(separator: "-")
        return parts.dropLast().sorted() + parts.suffix(1)
    }
    return canonical(a) == canonical(b)
}

/// Double-quoted like the default config
private func serializeWorkspaceName(_ name: String) -> String {
    let isPlain = name.unicodeScalars.allSatisfy { $0 != "\"" && $0 != "\\" && $0.properties.generalCategory != .control }
    return isPlain ? "\"\(name)\"" : serializeTomlString(name)
}

/// One line: the statement's key and spacing around `=` as written, the new value, and the comment that ended the statement
private func replacingValue(_ lines: [String], _ statement: TomlStatement, with value: String) -> String {
    let first = Array(lines[statement.lines.lowerBound])
    var valueStart = statement.keyEnd ?? 0
    while valueStart < first.count && first[valueStart] != "=" { valueStart += 1 }
    valueStart += 1
    while valueStart < first.count && (first[valueStart] == " " || first[valueStart] == "\t") { valueStart += 1 }
    return String(first[..<min(valueStart, first.count)]) + value + trailingComment(lines[statement.lines.upperBound - 1])
}

/// The `# comment` at the end of a line, with the whitespace before it
private func trailingComment(_ line: String) -> String {
    let chars = Array(line)
    var quote: Character? = nil
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if let open = quote {
            if open == "\"" && ch == "\\" { i += 1 } else if ch == open { quote = nil }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch == "#" {
            var start = i
            while start > 0 && (chars[start - 1] == " " || chars[start - 1] == "\t") { start -= 1 }
            return String(chars[start...])
        }
        i += 1
    }
    return ""
}

private extension TomlStatement {
    var keyPath: [String]? {
        if case .keyValue(let path, _) = kind { path } else { nil }
    }

    var tablePath: [String]? {
        if case .table(let path, false) = kind { path } else { nil }
    }

    var isTable: Bool {
        if case .table = kind { true } else { false }
    }
}
