import Common

/// `workspace-bar.*`: the menu bar group per workspace with the icons of its apps (Omarchy fork)
struct WorkspaceBarConfig: ConvenienceMutable, Equatable {
    var enabled: Bool = true
    var appIcons: Bool = true
}

private let workspaceBarParserTable: [String: any ParserProtocol<WorkspaceBarConfig>] = [
    "enabled": Parser(\.enabled, parseBool),
    "app-icons": Parser(\.appIcons, parseBool),
]

func parseWorkspaceBar(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> WorkspaceBarConfig {
    parseTable(rawConfig, WorkspaceBarConfig(), workspaceBarParserTable, backtrace, &c)
}
