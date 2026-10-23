import Common
import Foundation
import TOMLDecoder

// Read and write the [mode.*.binding] tables of a config file for the keybinding editor.
// Writing is a minimal text edit: untouched bindings, comments and the rest of the file are kept byte for byte.

/// A binding as the keybinding editor sees it: raw key notation and raw command strings, as written in the config
struct EditableBinding: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The key this binding had in the config file when it was loaded. nil for bindings added in the editor
    let originalKey: String?
    var key: String
    var commands: [String]

    init(id: UUID = UUID(), originalKey: String?, key: String, commands: [String]) {
        self.id = id
        self.originalKey = originalKey
        self.key = key
        self.commands = commands
    }

    /// Commands without the blank lines the user may leave while editing
    var normalizedCommands: [String] {
        commands.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct EditableMode: Equatable, Sendable {
    let name: String
    var bindings: [EditableBinding]
}

func readEditableModes(_ rawToml: String) -> Result<[EditableMode], String> {
    let table: [String: Any]
    do {
        table = try .init(try TOMLTable(source: rawToml))
    } catch {
        return .failure("Can't parse the config: \(error)")
    }
    let rawModes = table["mode"] as? [String: Any] ?? [:]
    let lines = splitLines(rawToml)
    let statements = scanTomlStatements(lines)
    let sections = bindingSections(statements)

    // 'main' first, then the order the sections appear in the file
    var modeNames: [String] = rawModes.keys.contains(mainModeId) ? [mainModeId] : []
    for section in sections where rawModes.keys.contains(section.mode) && !modeNames.contains(section.mode) {
        modeNames.append(section.mode)
    }
    modeNames += rawModes.keys.filter { !modeNames.contains($0) }.sorted()

    var result: [EditableMode] = []
    for modeName in modeNames {
        let rawBindings = (rawModes[modeName] as? [String: Any])?["binding"] as? [String: Any] ?? [:]
        var keys: [String] = []
        for key in sections.first(where: { $0.mode == modeName })?.entries.compactMap(\.singleKey) ?? []
            where rawBindings.keys.contains(key) && !keys.contains(key)
        {
            keys.append(key)
        }
        keys += rawBindings.keys.filter { !keys.contains($0) }.sorted()

        var bindings: [EditableBinding] = []
        for key in keys {
            let commands: [String]
            switch rawBindings[key] {
                case let string as String:
                    commands = [string]
                case let array as [Any]:
                    guard let strings = array as? [String] else {
                        return .failure("mode.\(modeName).binding.\(key): every command must be a string")
                    }
                    commands = strings
                default:
                    return .failure("mode.\(modeName).binding.\(key): expected a string or an array of strings")
            }
            bindings.append(EditableBinding(originalKey: key, key: key, commands: commands))
        }
        result.append(EditableMode(name: modeName, bindings: bindings))
    }
    return .success(result)
}

/// Returns `rawToml` with the bindings of `desired` modes written into it.
/// Modes missing from `desired` are left untouched.
func rewriteBindings(_ rawToml: String, _ desired: [EditableMode]) -> Result<String, String> {
    let original: [EditableMode]
    switch readEditableModes(rawToml) {
        case .success(let it): original = it
        case .failure(let it): return .failure(it)
    }
    let originalCommands: [String: [String: [String]]] = original.reduce(into: [:]) { acc, mode in
        acc[mode.name] = mode.bindings.reduce(into: [:]) { $0[$1.key] = $1.commands }
    }

    var lines = splitLines(rawToml)
    let sections = bindingSections(scanTomlStatements(lines))
    var edits: [(range: Range<Int>, replacement: [String])] = []
    var appendedSections: [String] = []

    for mode in desired {
        let section = sections.first { $0.mode == mode.name }
        let commandsBefore = originalCommands[mode.name] ?? [:]
        var byOriginalKey: [String: EditableBinding] = [:]
        for binding in mode.bindings {
            if let key = binding.originalKey, byOriginalKey[key] == nil {
                byOriginalKey[key] = binding
            }
        }
        var handled: Set<UUID> = []
        for entry in section?.entries ?? [] {
            guard let key = entry.singleKey, let keyEnd = entry.keyEnd else { continue }
            guard let binding = byOriginalKey[key] else {
                edits.append((entry.lines, [])) // Deleted
                continue
            }
            handled.insert(binding.id)
            let commands = binding.normalizedCommands
            if commands == commandsBefore[key] {
                if binding.key == key { continue } // Unchanged
                // Only the shortcut changed: keep the value text (and its trailing comment) verbatim
                let firstLine = Array(lines[entry.lines.lowerBound])
                let indent = String(firstLine.prefix { $0 == " " || $0 == "\t" })
                let rest = String(firstLine[keyEnd...])
                edits.append((entry.lines.lowerBound ..< entry.lines.lowerBound + 1, [indent + serializeTomlKey(binding.key) + rest]))
            } else {
                edits.append((entry.lines, [entryIndent(lines, entry) + serializeBinding(binding)]))
            }
        }

        let added = mode.bindings.filter { !handled.contains($0.id) }
        if added.isEmpty { continue }
        if let section {
            let indent = section.entries.first.map { entryIndent(lines, $0) } ?? "    "
            let insertAt = section.entries.last?.lines.upperBound ?? section.header.lines.upperBound
            edits.append((insertAt ..< insertAt, added.map { indent + serializeBinding($0) }))
        } else {
            appendedSections += ["", "[mode.\(serializeTomlKey(mode.name)).binding]"] + added.map { "    " + serializeBinding($0) }
        }
    }
    if !appendedSections.isEmpty {
        let end = lines.last == "" ? lines.count - 1 : lines.count
        edits.append((end ..< end, appendedSections))
    }
    for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        lines.replaceSubrange(edit.range, with: edit.replacement)
    }
    let result = lines.joined(separator: "\n")

    // Never hand back text that doesn't round-trip to exactly what was asked for
    switch readEditableModes(result) {
        case .failure(let msg):
            return .failure("Writing the bindings would break the config (\(msg)). Please edit the config file by hand.")
        case .success(let written):
            for mode in desired {
                let want = Dictionary(mode.bindings.map { ($0.key, $0.normalizedCommands) }, uniquingKeysWith: { a, _ in a })
                let got = written.first { $0.name == mode.name }?.bindings
                    .reduce(into: [String: [String]]()) { $0[$1.key] = $1.commands } ?? [:]
                if want != got {
                    return .failure("Bindings of mode '\(mode.name)' are defined in a way the editor can't update. Please edit the config file by hand.")
                }
            }
    }
    return .success(result)
}

func serializeBinding(_ binding: EditableBinding) -> String {
    let commands = binding.normalizedCommands
    let value = commands.count == 1
        ? serializeTomlString(commands[0])
        : "[" + commands.map(serializeTomlString).joined(separator: ", ") + "]"
    return "\(serializeTomlKey(binding.key)) = \(value)"
}

func serializeTomlKey(_ key: String) -> String {
    let isBare = !key.isEmpty && key.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_"
    }
    return isBare ? key : escapedTomlBasicString(key)
}

func serializeTomlString(_ value: String) -> String {
    let hasControl = value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    if hasControl { return escapedTomlBasicString(value) }
    if !value.contains("'") { return "'\(value)'" }
    if !value.contains("\"") && !value.contains("\\") { return "\"\(value)\"" }
    if !value.contains("'''") && !value.hasSuffix("'") { return "'''\(value)'''" }
    return escapedTomlBasicString(value)
}

private func escapedTomlBasicString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where scalar.properties.generalCategory == .control:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            default: result.unicodeScalars.append(scalar)
        }
    }
    return result + "\""
}

// MARK: - Minimal TOML statement scanner

struct TomlStatement {
    enum Kind {
        case table(path: [String], isArrayOfTables: Bool)
        /// `keyEnd` is the character offset in the first line right after the key
        case keyValue(path: [String], keyEnd: Int)
        case unknown
    }
    let kind: Kind
    /// Line indices. Blank and comment-only lines are never part of a statement
    let lines: Range<Int>

    var singleKey: String? {
        if case .keyValue(let path, _) = kind, path.count == 1 { return path[0] }
        return nil
    }

    var keyEnd: Int? {
        if case .keyValue(_, let keyEnd) = kind { return keyEnd }
        return nil
    }
}

struct TomlBindingSection {
    let mode: String
    let header: TomlStatement
    let entries: [TomlStatement]
}

func splitLines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

func bindingSections(_ statements: [TomlStatement]) -> [TomlBindingSection] {
    var result: [TomlBindingSection] = []
    var index = 0
    while index < statements.count {
        guard case .table(let path, false) = statements[index].kind,
              path.count == 3, path[0] == "mode", path[2] == "binding"
        else {
            index += 1
            continue
        }
        let header = statements[index]
        var entries: [TomlStatement] = []
        index += 1
        while index < statements.count {
            if case .table = statements[index].kind { break }
            entries.append(statements[index])
            index += 1
        }
        result.append(TomlBindingSection(mode: path[1], header: header, entries: entries))
    }
    return result
}

private enum TomlStringState { case none, basic, literal, multilineBasic, multilineLiteral }

func scanTomlStatements(_ lines: [String]) -> [TomlStatement] {
    var result: [TomlStatement] = []
    var state = TomlStringState.none
    var depth = 0
    var start: Int? = nil
    for (index, line) in lines.enumerated() {
        if start == nil {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            start = index
        }
        scanLine(Array(line), &state, &depth)
        if state == .none && depth <= 0, let first = start {
            result.append(TomlStatement(kind: classifyStatement(Array(lines[first])), lines: first ..< index + 1))
            start = nil
            depth = 0
        }
    }
    if let first = start {
        result.append(TomlStatement(kind: .unknown, lines: first ..< lines.count))
    }
    return result
}

private func scanLine(_ chars: [Character], _ state: inout TomlStringState, _ depth: inout Int) {
    func has(_ i: Int, _ needle: Character, count: Int) -> Bool {
        i + count <= chars.count && chars[i ..< i + count].allSatisfy { $0 == needle }
    }
    func closeMultiline(_ i: inout Int, _ quote: Character) {
        i += 3
        var extra = 0
        while extra < 2 && i < chars.count && chars[i] == quote { // Up to two quotes may precede the closing delimiter
            i += 1
            extra += 1
        }
        state = .none
    }
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        switch state {
            case .none:
                switch ch {
                    case "#": return // Comment until the end of the line
                    case "\"" where has(i, "\"", count: 3): state = .multilineBasic; i += 3; continue
                    case "\"": state = .basic
                    case "'" where has(i, "'", count: 3): state = .multilineLiteral; i += 3; continue
                    case "'": state = .literal
                    case "[", "{": depth += 1
                    case "]", "}": depth -= 1
                    default: break
                }
            case .basic:
                if ch == "\\" { i += 2; continue }
                if ch == "\"" { state = .none }
            case .literal:
                if ch == "'" { state = .none }
            case .multilineBasic:
                if ch == "\\" { i += 2; continue }
                if has(i, "\"", count: 3) { closeMultiline(&i, "\""); continue }
            case .multilineLiteral:
                if has(i, "'", count: 3) { closeMultiline(&i, "'"); continue }
        }
        i += 1
    }
    if state == .basic || state == .literal { state = .none } // Single-line strings can't span lines
}

private func classifyStatement(_ chars: [Character]) -> TomlStatement.Kind {
    var i = 0
    while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 }
    if i < chars.count && chars[i] == "[" {
        let isArray = i + 1 < chars.count && chars[i + 1] == "["
        i += isArray ? 2 : 1
        guard let path = parseKeyPath(chars, &i), i < chars.count, chars[i] == "]" else { return .unknown }
        return .table(path: path, isArrayOfTables: isArray)
    }
    guard let path = parseKeyPath(chars, &i), i < chars.count, chars[i] == "=" else { return .unknown }
    var keyEnd = i
    while keyEnd > 0 && (chars[keyEnd - 1] == " " || chars[keyEnd - 1] == "\t") { keyEnd -= 1 }
    return .keyValue(path: path, keyEnd: keyEnd)
}

/// Parses a dotted TOML key starting at `i`. Leaves `i` at the first character after the key and trailing whitespace
private func parseKeyPath(_ chars: [Character], _ i: inout Int) -> [String]? {
    func skipWhitespace() { while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 } }
    var path: [String] = []
    while true {
        skipWhitespace()
        guard i < chars.count else { return nil }
        var part = ""
        switch chars[i] {
            case "\"":
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                            case "n": part.append("\n")
                            case "t": part.append("\t")
                            default: part.append(chars[i])
                        }
                    } else {
                        part.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
            case "'":
                i += 1
                while i < chars.count && chars[i] != "'" {
                    part.append(chars[i])
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
            default:
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "-" || chars[i] == "_") {
                    part.append(chars[i])
                    i += 1
                }
                if part.isEmpty { return nil }
        }
        path.append(part)
        skipWhitespace()
        if i < chars.count && chars[i] == "." {
            i += 1
            continue
        }
        return path
    }
}

private func entryIndent(_ lines: [String], _ entry: TomlStatement) -> String {
    String(lines[entry.lines.lowerBound].prefix { $0 == " " || $0 == "\t" })
}
