import Common

func parseWorkspaceLayout(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<WorkspaceLayout> {
    parseString(raw, backtrace).flatMap {
        WorkspaceLayout(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse workspace layout '\($0)'. Possible values: \(WorkspaceLayout.unionLiteral)"))
    }
}

/// `[workspace-layout]` table: workspace name to layout
func parseWorkspaceLayouts(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [String: WorkspaceLayout] {
    guard let dict = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return [:]
    }
    var result: [String: WorkspaceLayout] = [:]
    for (name, value) in dict {
        if let layout = parseWorkspaceLayout(value, backtrace + .key(name)).getOrNil(appendErrorTo: &c.errors) {
            result[name] = layout
        }
    }
    return result
}
