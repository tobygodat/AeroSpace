public struct WorkspaceLayoutCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceLayout,
        help: workspace_layout_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [newMandatoryPosArgParser(\.toggleBetween, parseToggleBetween, placeholder: Target.unionLiteral)],
    )

    /// Like `layout`: the first target the workspace isn't in already wins. `next` cycles
    public var toggleBetween: Lateinit<[Target]> = .uninitialized

    public init(rawArgs: [String], toggleBetween: [Target]) {
        self.commonState = .init(rawArgs.slice)
        self.toggleBetween = .initialized(toggleBetween)
    }

    public enum Target: Equatable, Sendable {
        case layout(WorkspaceLayout)
        case next

        public static var unionLiteral: String {
            (WorkspaceLayout.allCases.map(\.rawValue) + ["next"]).joinedCliArgs
        }
    }
}

private func parseToggleBetween(input: PosArgParserInput) -> ParsedCliArgs<[WorkspaceLayoutCmdArgs.Target]> {
    let args = input.nonFlagArgs()
    var result: [WorkspaceLayoutCmdArgs.Target] = []
    for (i, arg) in args.enumerated() {
        if arg == "next" {
            result.append(.next)
        } else if let layout = WorkspaceLayout(rawValue: arg) {
            result.append(.layout(layout))
        } else {
            return .fail(
                "Can't parse '\(arg)'\nPossible values: \(WorkspaceLayoutCmdArgs.Target.unionLiteral)",
                advanceBy: i + 1,
            )
        }
    }
    return .succ(result, advanceBy: args.count)
}

func parseWorkspaceLayoutCmdArgs(_ args: StrArrSlice) -> ParsedCmd<WorkspaceLayoutCmdArgs> {
    parseSpecificCmdArgs(WorkspaceLayoutCmdArgs(rawArgs: args), args)
        .filter("'next' can't be combined with other targets") { $0.toggleBetween.val.contains(.next).implies($0.toggleBetween.val.count == 1) }
}
