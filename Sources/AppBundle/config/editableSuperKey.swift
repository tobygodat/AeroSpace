import Common
import Foundation
import TOMLDecoder

// Minimal-diff edits for the Super key pane: the `super-key` setting, and moving bindings from ⌥ to Super

/// `rawToml` with `super-key` set. An existing line is edited in place, keeping a trailing comment. A new line goes after
/// the last top-level setting, so it stays out of every table
func rewriteSuperKeySetting(_ rawToml: String, _ superKey: SuperKey) -> Result<String, String> {
    var lines = splitLines(rawToml)
    let statements = scanTomlStatements(lines)
    let topLevel = statements.prefix { if case .table = $0.kind { false } else { true } }
    let newLine = "super-key = '\(superKey.rawValue)'"
    if let existing = topLevel.first(where: { $0.singleKey == "super-key" }) {
        let line = lines[existing.lines.lowerBound]
        let simpleValue = /^(\s*super-key\s*=\s*)(?:'[^']*'|"[^"]*")(\s*(?:#.*)?)$/
        if existing.lines.count == 1, let match = line.wholeMatch(of: simpleValue) {
            lines[existing.lines.lowerBound] = "\(match.1)'\(superKey.rawValue)'\(match.2)"
        } else {
            lines.replaceSubrange(existing.lines, with: [newLine])
        }
    } else if let last = topLevel.last(where: { if case .keyValue = $0.kind { true } else { false } }) {
        lines.insert(newLine, at: last.lines.upperBound)
    } else if let firstTable = statements.first {
        lines.insert(contentsOf: [newLine, ""], at: firstTable.lines.lowerBound)
    } else {
        lines.insert(newLine, at: lines.last == "" ? lines.count - 1 : lines.count)
    }
    let result = lines.joined(separator: "\n")
    guard let table = try? [String: Any](TOMLTable(source: result)), table["super-key"] as? String == superKey.rawValue else {
        return .failure("super-key is written in a way the settings can't update. Please edit the config file by hand.")
    }
    return .success(result)
}

struct ModeBindingKey: Hashable, Sendable {
    let mode: String
    let key: String
}

struct ModifierSwap: Equatable, Sendable {
    var modes: [EditableMode]
    /// The new keys of the bindings that changed
    var swapped: [ModeBindingKey] = []
    /// Bindings left alone because the new keys are already bound in their mode
    var skipped: [ModeBindingKey] = []
}

/// Replaces the `from` modifier with `to` in binding keys, e.g. "alt-shift-1" → "super-shift-1". Only the keys change.
/// `only` limits it to these bindings, by their current keys
func swapBindingModifier(_ from: String, _ to: String, in modes: [EditableMode], only: Set<ModeBindingKey>? = nil) -> ModifierSwap {
    var result = ModifierSwap(modes: modes)
    for modeIndex in modes.indices {
        let mode = modes[modeIndex]
        var taken = Set(mode.bindings.map { shortcutIdentity($0.key) })
        for (index, binding) in mode.bindings.enumerated() {
            var parts = binding.key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            let modifierCount = parts.count - 1
            guard modifierCount > 0, let position = parts.prefix(modifierCount).firstIndex(of: from),
                  !parts.prefix(modifierCount).contains(to),
                  only?.contains(ModeBindingKey(mode: mode.name, key: binding.key)) ?? true
            else { continue }
            parts[position] = to
            let newKey = parts.joined(separator: "-")
            guard taken.insert(shortcutIdentity(newKey)).inserted else {
                result.skipped.append(ModeBindingKey(mode: mode.name, key: binding.key))
                continue
            }
            taken.remove(shortcutIdentity(binding.key))
            result.modes[modeIndex].bindings[index].key = newKey
            result.swapped.append(ModeBindingKey(mode: mode.name, key: newKey))
        }
    }
    return result
}

/// The same shortcut written in any modifier order: "shift-alt-1" and "alt-shift-1" are one
private func shortcutIdentity(_ key: String) -> String {
    var parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    let last = parts.popLast() ?? ""
    return parts.sorted().joined(separator: "-") + ">" + last
}

/// Bindings whose keys use `modifier`, in every mode
func bindingsUsingModifier(_ modifier: String, in modes: [EditableMode]) -> [EditableBinding] {
    modes.flatMap(\.bindings).filter { $0.key.split(separator: "-").dropLast().contains(Substring(modifier)) }
}
