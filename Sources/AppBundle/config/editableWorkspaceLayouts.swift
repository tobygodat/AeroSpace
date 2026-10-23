import Common
import Foundation
import TOMLDecoder

// Read and write `default-workspace-layout`, `scrolling-column-width` and the `[workspace-layout]` table for the
// Layouts settings pane. Writing is a minimal text edit, like editableBindings.swift: comments and every other line
// are kept byte for byte.

/// The config keys the Layouts pane edits
struct WorkspaceLayoutSettings: Equatable, Sendable {
    /// nil when `default-workspace-layout` is absent, so the implicit default (tiles) applies
    var defaultLayout: WorkspaceLayout?
    /// `[workspace-layout]` entries in file order
    var overrides: [WorkspaceLayoutOverride]
    /// nil when `scrolling-column-width` is absent, so the implicit default applies
    var scrollingColumnWidthPercent: Int? = nil

    var effectiveDefault: WorkspaceLayout { defaultLayout ?? .tiles }
    var effectiveScrollingColumnWidthPercent: Int { scrollingColumnWidthPercent ?? Config().scrollingColumnWidthPercent }

    var overridesByWorkspace: [String: WorkspaceLayout] {
        Dictionary(overrides.map { ($0.workspace, $0.layout) }, uniquingKeysWith: { a, _ in a })
    }
}

struct WorkspaceLayoutOverride: Equatable, Sendable {
    var workspace: String
    var layout: WorkspaceLayout
}

private let defaultLayoutKey = "default-workspace-layout"
private let columnWidthKey = "scrolling-column-width"
private let overridesKey = "workspace-layout"

/// Absent keys are fine. Fails only for TOML that doesn't parse and for values that aren't layouts
func readWorkspaceLayoutSettings(_ rawToml: String) -> Result<WorkspaceLayoutSettings, String> {
    let table: [String: Any]
    do {
        table = try .init(try TOMLTable(source: rawToml))
    } catch {
        return .failure("Can't parse the config: \(error)")
    }

    var defaultLayout: WorkspaceLayout? = nil
    if let raw = table[defaultLayoutKey] {
        guard let layout = (raw as? String).flatMap(WorkspaceLayout.init(rawValue:)) else {
            return .failure("\(defaultLayoutKey): expected one of \(WorkspaceLayout.unionLiteral)")
        }
        defaultLayout = layout
    }

    var columnWidth: Int? = nil
    if let raw = table[columnWidthKey] {
        guard let percent = (raw as? Int) ?? (raw as? Int64).map(Int.init), scrollingColumnWidthRange.contains(percent) else {
            return .failure("\(columnWidthKey): expected a whole number in [\(scrollingColumnWidthRange.lowerBound), \(scrollingColumnWidthRange.upperBound)]")
        }
        columnWidth = percent
    }

    let rawOverrides: [String: Any]
    switch table[overridesKey] {
        case nil: rawOverrides = [:]
        case let dict as [String: Any]: rawOverrides = dict
        default: return .failure("\(overridesKey): expected a table of workspace names to layouts")
    }
    // File order, then whatever the scanner can't see (inline tables, dotted keys) in natural order
    var names: [String] = []
    for name in overridesSection(scanTomlStatements(splitLines(rawToml)))?.entries.compactMap(\.singleKey) ?? []
        where rawOverrides.keys.contains(name) && !names.contains(name)
    {
        names.append(name)
    }
    names += rawOverrides.keys.filter { !names.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    var overrides: [WorkspaceLayoutOverride] = []
    for name in names {
        guard let layout = (rawOverrides[name] as? String).flatMap(WorkspaceLayout.init(rawValue:)) else {
            return .failure("\(overridesKey).\(name): expected one of \(WorkspaceLayout.unionLiteral)")
        }
        overrides.append(WorkspaceLayoutOverride(workspace: name, layout: layout))
    }
    return .success(WorkspaceLayoutSettings(defaultLayout: defaultLayout, overrides: overrides, scrollingColumnWidthPercent: columnWidth))
}

/// Returns `rawToml` with `desired` written into it. Only the lines of changed settings are touched
func rewriteWorkspaceLayouts(_ rawToml: String, _ desired: WorkspaceLayoutSettings) -> Result<String, String> {
    let current: WorkspaceLayoutSettings
    switch readWorkspaceLayoutSettings(rawToml) {
        case .success(let it): current = it
        case .failure(let it): return .failure(it)
    }
    var lines = splitLines(rawToml)
    let statements = scanTomlStatements(lines)
    var edits: [(range: Range<Int>, replacement: [String])] = []

    let topLevel = statements.prefix { if case .table = $0.kind { false } else { true } }
    // A new top-level key goes right after the closest related key the file already has
    func insertTopLevel(_ key: String, _ value: String, after anchors: [String]) {
        let anchor = anchors.lazy.compactMap { name in topLevel.first { $0.singleKey == name } }.first
        let insertAt = anchor?.lines.upperBound ?? 0
        let indent = anchor.map { lineIndent(lines[$0.lines.lowerBound]) } ?? ""
        edits.append((insertAt ..< insertAt, [indent + "\(key) = \(value)"]))
    }
    if desired.defaultLayout != current.defaultLayout {
        let value = desired.defaultLayout.map { serializeTomlString($0.rawValue) }
        if let statement = topLevel.first(where: { $0.singleKey == defaultLayoutKey }) {
            edits.append((statement.lines, value.map { [rewrittenStatement(lines, statement, key: defaultLayoutKey, value: $0)] } ?? []))
        } else if let value {
            insertTopLevel(defaultLayoutKey, value, after: ["default-root-container-layout", "config-version"])
        }
    }
    if desired.scrollingColumnWidthPercent != current.scrollingColumnWidthPercent {
        let value = desired.scrollingColumnWidthPercent.map { String($0) }
        if let statement = topLevel.first(where: { $0.singleKey == columnWidthKey }) {
            edits.append((statement.lines, value.map { [rewrittenStatement(lines, statement, key: columnWidthKey, value: $0)] } ?? []))
        } else if let value {
            insertTopLevel(columnWidthKey, value, after: [defaultLayoutKey, "default-root-container-layout", "config-version"])
        }
    }

    if desired.overrides != current.overrides {
        let section = overridesSection(statements)
        let before = current.overridesByWorkspace
        let after = desired.overridesByWorkspace
        var inSection: Set<String> = []
        for entry in section?.entries ?? [] {
            guard let name = entry.singleKey else { continue }
            inSection.insert(name)
            guard let layout = after[name] else {
                edits.append((entry.lines, []))
                continue
            }
            if layout != before[name] {
                edits.append((entry.lines, [rewrittenStatement(lines, entry, key: name, value: serializeTomlString(layout.rawValue))]))
            }
        }
        let added = desired.overrides.filter { !inSection.contains($0.workspace) }
        func entryLines(_ indent: String) -> [String] {
            added.map { indent + serializeTomlKey($0.workspace) + " = " + serializeTomlString($0.layout.rawValue) }
        }
        if !added.isEmpty {
            if let section {
                let indent = section.entries.first.map { lineIndent(lines[$0.lines.lowerBound]) } ?? "    "
                let insertAt = section.entries.last?.lines.upperBound ?? section.header.lines.upperBound
                edits.append((insertAt ..< insertAt, entryLines(indent)))
            } else {
                let end = lines.last == "" ? lines.count - 1 : lines.count
                let blank = end > 0 && !lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty ? [""] : []
                edits.append((end ..< end, blank + ["[\(overridesKey)]"] + entryLines("    ")))
            }
        }
    }

    // Bottom up, so earlier ranges stay valid. On a tie the later edit goes first and ends up below the earlier one
    for (_, edit) in edits.enumerated().sorted(by: { ($0.element.range.lowerBound, $0.offset) > ($1.element.range.lowerBound, $1.offset) }) {
        lines.replaceSubrange(edit.range, with: edit.replacement)
    }
    let result = lines.joined(separator: "\n")

    // Never hand back text that doesn't read back as exactly what was asked for
    switch readWorkspaceLayoutSettings(result) {
        case .failure(let msg):
            return .failure("Writing the layouts would break the config (\(msg)). Please edit the config file by hand.")
        case .success(let written):
            if written.defaultLayout != desired.defaultLayout || written.overridesByWorkspace != desired.overridesByWorkspace ||
                written.scrollingColumnWidthPercent != desired.scrollingColumnWidthPercent
            {
                return .failure("The workspace layouts are defined in a way the editor can't update. Please edit the config file by hand.")
            }
    }
    return .success(result)
}

/// The `[workspace-layout]` header and the statements up to the next table header
private func overridesSection(_ statements: [TomlStatement]) -> (header: TomlStatement, entries: [TomlStatement])? {
    guard let headerIndex = statements.firstIndex(where: {
        if case .table(let path, false) = $0.kind { path == [overridesKey] } else { false }
    }) else { return nil }
    let entries = statements[(headerIndex + 1)...].prefix { if case .table = $0.kind { false } else { true } }
    return (statements[headerIndex], Array(entries))
}

/// The statement with a new value. A one-line string or integer value is swapped in place, keeping the key's
/// spelling, the spacing and a trailing comment. Anything else becomes a fresh `key = value` line
private func rewrittenStatement(_ lines: [String], _ statement: TomlStatement, key: String, value: String) -> String {
    let line = lines[statement.lines.lowerBound]
    if statement.lines.count == 1, let keyEnd = statement.keyEnd, let valueRange = scalarValueRange(Array(line), from: keyEnd) {
        let chars = Array(line)
        return String(chars[..<valueRange.lowerBound]) + value + String(chars[valueRange.upperBound...])
    }
    return lineIndent(line) + serializeTomlKey(key) + " = " + value
}

/// Character range of the single-line string or integer after `= ` in a key-value line, or nil if the value is
/// something else
private func scalarValueRange(_ chars: [Character], from keyEnd: Int) -> Range<Int>? {
    var i = keyEnd
    func skipWhitespace() { while i < chars.count && (chars[i] == " " || chars[i] == "\t") { i += 1 } }
    skipWhitespace()
    guard i < chars.count, chars[i] == "=" else { return nil }
    i += 1
    skipWhitespace()
    let start = i
    guard i < chars.count else { return nil }
    if chars[i].isASCII && (chars[i].isNumber || chars[i] == "-" || chars[i] == "+") {
        i += 1
        while i < chars.count && chars[i].isASCII && (chars[i].isNumber || chars[i] == "_") { i += 1 }
        // A plain decimal ends the value; anything else (0x32, 1e3, 2.5) gets a fresh line instead
        return i == chars.count || chars[i] == " " || chars[i] == "\t" || chars[i] == "#" ? start ..< i : nil
    }
    guard chars[i] == "'" || chars[i] == "\"" else { return nil }
    let quote = chars[i]
    if i + 2 < chars.count && chars[i + 1] == quote && chars[i + 2] == quote { return nil } // Multiline string
    i += 1
    while i < chars.count && chars[i] != quote {
        i += quote == "\"" && chars[i] == "\\" ? 2 : 1
    }
    guard i < chars.count else { return nil }
    return start ..< i + 1
}

private func lineIndent(_ line: String) -> String {
    String(line.prefix { $0 == " " || $0 == "\t" })
}
