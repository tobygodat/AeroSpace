import Common

func parseWorkspaceLayout(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<WorkspaceLayout> {
    parseString(raw, backtrace).flatMap {
        WorkspaceLayout(rawValue: $0)
            .toResult(.init(backtrace, "Can't parse workspace layout '\($0)'. Possible values: \(WorkspaceLayout.unionLiteral)"))
    }
}

let scrollingColumnWidthRange = 10 ... 100

/// `scrolling-column-width`: percent of the screen width
func parseScrollingColumnWidth(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).flatMap {
        scrollingColumnWidthRange.contains($0)
            ? .success($0)
            : .failure(.init(backtrace, "scrolling-column-width must be in [\(scrollingColumnWidthRange.lowerBound), \(scrollingColumnWidthRange.upperBound)] (percent of the screen width)"))
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
