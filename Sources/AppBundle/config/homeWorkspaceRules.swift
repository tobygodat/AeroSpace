import Common
import Foundation
import TOMLDecoder

// An app's home workspace is an `[[on-window-detected]]` rule of exactly this shape:
//
//     [[on-window-detected]]
//         if.app-id = 'com.google.Chrome'
//         check-further-callbacks = true
//         run = 'move-node-to-workspace 4'
//
// `check-further-callbacks` is optional. The editor writes it and puts new rules first, because AeroSpace stops at the
// first rule that matches a window: that way the home workspace applies, and so do the rules that follow.
// Other rules are never shown or touched. Writing is a minimal text edit, like the bindings in editableBindings.swift.

struct HomeWorkspaceRule: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The app id this rule had in the config file when it was loaded. nil for rules added in the editor
    let originalAppId: String?
    var appId: String
    var workspace: String

    init(id: UUID = UUID(), originalAppId: String?, appId: String, workspace: String) {
        self.id = id
        self.originalAppId = originalAppId
        self.appId = appId
        self.workspace = workspace
    }
}

/// Workspace names the editor writes without quoting, and so can read back. "next" and "prev" are relative targets, not names
func isPlainWorkspaceName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix("-") && !["next", "prev"].contains(name) &&
        name.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
}

func readHomeWorkspaceRules(_ rawToml: String) -> Result<[HomeWorkspaceRule], String> {
    homeRuleBlocks(rawToml).map { blocks in
        blocks.map { HomeWorkspaceRule(originalAppId: $0.appId, appId: $0.appId, workspace: $0.workspace) }
    }
}

/// Returns `rawToml` with exactly `desired` as its home workspace rules
func rewriteHomeWorkspaceRules(_ rawToml: String, _ desired: [HomeWorkspaceRule]) -> Result<String, String> {
    let blocks: [HomeRuleBlock]
    switch homeRuleBlocks(rawToml) {
        case .success(let it): blocks = it
        case .failure(let it): return .failure(it)
    }
    var lines = splitLines(rawToml)
    var edits: [(range: Range<Int>, replacement: [String])] = []
    var byOriginalAppId: [String: HomeWorkspaceRule] = [:]
    for rule in desired {
        if let appId = rule.originalAppId, byOriginalAppId[appId] == nil { byOriginalAppId[appId] = rule }
    }
    var handled: Set<UUID> = []
    for block in blocks {
        guard let rule = byOriginalAppId[block.appId] else {
            edits.append((blockRangeForDeletion(block, lines), []))
            continue
        }
        handled.insert(rule.id)
        if rule.appId != block.appId {
            edits.append(replacingValue(of: block.appIdStatement, in: lines, with: serializeTomlString(rule.appId)))
        }
        if rule.workspace != block.workspace {
            edits.append(replacingValue(of: block.runStatement, in: lines, with: serializeTomlString(moveToWorkspaceCommand(rule.workspace))))
        }
    }

    let added = desired.filter { !handled.contains($0.id) }
    if !added.isEmpty {
        let sections = onWindowDetectedSections(scanTomlStatements(lines))
        let indent = sections.lazy.flatMap(\.entries).first
            .map { String(lines[$0.lines.lowerBound].prefix { $0 == " " || $0 == "\t" }) } ?? "    "
        let blocks = added.map { rule in
            [
                "[[on-window-detected]]",
                indent + "if.app-id = " + serializeTomlString(rule.appId),
                indent + "check-further-callbacks = true",
                indent + "run = " + serializeTomlString(moveToWorkspaceCommand(rule.workspace)),
            ]
        }
        if let first = sections.first {
            // Above the first rule and the comment that introduces it
            var insertAt = first.header.lines.lowerBound
            while insertAt > 0 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { insertAt -= 1 }
            edits.append((insertAt ..< insertAt, blocks.flatMap { $0 + [""] }))
        } else {
            let insertAt = lines.last == "" ? lines.count - 1 : lines.count
            edits.append((insertAt ..< insertAt, blocks.flatMap { [""] + $0 }))
        }
    }
    for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        lines.replaceSubrange(edit.range, with: edit.replacement)
    }
    let result = lines.joined(separator: "\n")

    // Never hand back text that doesn't round-trip to exactly what was asked for, or that changed other rules
    let cantUpdate = "The on-window-detected rules are written in a way the editor can't update. Please edit the config file by hand."
    guard case .success(let written) = homeRuleBlocks(result) else { return .failure(cantUpdate) }
    let want = Set(desired.map { "\($0.appId)\n\($0.workspace)" })
    let got = Set(written.map { "\($0.appId)\n\($0.workspace)" })
    if want != got || written.count != desired.count || otherRules(rawToml, blocks) != otherRules(result, written) {
        return .failure(cantUpdate)
    }
    return .success(result)
}

private func moveToWorkspaceCommand(_ workspace: String) -> String { "move-node-to-workspace \(workspace)" }

private struct HomeRuleBlock {
    let appId: String
    let workspace: String
    /// Position among all `[[on-window-detected]]` entries
    let index: Int
    let header: TomlStatement
    let appIdStatement: TomlStatement
    let runStatement: TomlStatement
    let lastLine: Int
}

private struct OnWindowDetectedSection {
    let header: TomlStatement
    let entries: [TomlStatement]
}

private func onWindowDetectedSections(_ statements: [TomlStatement]) -> [OnWindowDetectedSection] {
    var result: [OnWindowDetectedSection] = []
    var index = 0
    while index < statements.count {
        guard case .table(let path, true) = statements[index].kind, path == ["on-window-detected"] else {
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
        result.append(OnWindowDetectedSection(header: header, entries: entries))
    }
    return result
}

/// The text of `[[on-window-detected]]` entries maps 1:1 to the parsed array: TOML forbids mixing them with an inline array
private func homeRuleBlocks(_ rawToml: String) -> Result<[HomeRuleBlock], String> {
    let table: [String: Any]
    do {
        table = try .init(try TOMLTable(source: rawToml))
    } catch {
        return .failure("Can't parse the config: \(error)")
    }
    let parsedRules = table["on-window-detected"] as? [Any] ?? []
    let sections = onWindowDetectedSections(scanTomlStatements(splitLines(rawToml)))
    if parsedRules.count != sections.count {
        return .failure("Home workspaces can only be edited when on-window-detected is written as [[on-window-detected]] tables. Please edit them in the config file.")
    }
    var result: [HomeRuleBlock] = []
    for (index, section) in sections.enumerated() {
        guard let rule = parsedRules[index] as? [String: Any],
              Set(rule.keys) == ["if", "run"] || Set(rule.keys) == ["if", "run", "check-further-callbacks"] && rule["check-further-callbacks"] as? Bool == true,
              let condition = rule["if"] as? [String: Any], condition.count == 1,
              let appId = condition["app-id"] as? String,
              let workspace = homeWorkspace(fromRun: rule["run"]),
              !result.contains(where: { $0.appId == appId }),
              section.entries.count == rule.count,
              let appIdStatement = section.entries.first(where: { $0.keyPath == ["if", "app-id"] }),
              let runStatement = section.entries.first(where: { $0.keyPath == ["run"] }),
              let lastLine = section.entries.map(\.lines.upperBound).max()
        else { continue }
        result.append(HomeRuleBlock(
            appId: appId, workspace: workspace, index: index,
            header: section.header, appIdStatement: appIdStatement, runStatement: runStatement, lastLine: lastLine,
        ))
    }
    return .success(result)
}

private func homeWorkspace(fromRun run: Any?) -> String? {
    let command: String
    switch run {
        case let string as String: command = string
        case let array as [Any] where array.count == 1: guard let string = array[0] as? String else { return nil }; command = string
        default: return nil
    }
    let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard words.count == 2, words[0] == "move-node-to-workspace", isPlainWorkspaceName(words[1]) else { return nil }
    return words[1]
}

/// Every `[[on-window-detected]]` entry that isn't a home workspace rule, as parsed values
private func otherRules(_ rawToml: String, _ blocks: [HomeRuleBlock]) -> NSArray {
    let table = (try? TOMLTable(source: rawToml)).flatMap { try? [String: Any]($0) } ?? [:]
    let all = table["on-window-detected"] as? [Any] ?? []
    let managed = Set(blocks.map(\.index))
    return all.enumerated().filter { !managed.contains($0.offset) }.map(\.element) as NSArray
}

private func replacingValue(of statement: TomlStatement, in lines: [String], with value: String) -> (range: Range<Int>, replacement: [String]) {
    let firstLine = lines[statement.lines.lowerBound]
    let key = String(firstLine.prefix(statement.keyEnd ?? 0))
    return (statement.lines, [key + " = " + value])
}

/// The block's lines, plus the blank line before it when that would otherwise leave two blank lines in a row
private func blockRangeForDeletion(_ block: HomeRuleBlock, _ lines: [String]) -> Range<Int> {
    var start = block.header.lines.lowerBound
    let end = block.lastLine
    let isBlank = { (index: Int) in lines[index].trimmingCharacters(in: .whitespaces).isEmpty }
    if start > 0 && isBlank(start - 1) && (end >= lines.count || isBlank(end)) {
        start -= 1
    }
    return start ..< end
}

extension TomlStatement {
    var keyPath: [String]? {
        if case .keyValue(let path, _) = kind { return path }
        return nil
    }
}
