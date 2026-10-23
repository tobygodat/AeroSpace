public struct FocusAppCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .focusApp,
        help: focus_app_help_generated,
        flags: [
            "--default-browser": trueBoolFlag(\.defaultBrowser),
            "--default-terminal": trueBoolFlag(\.defaultTerminal),
        ],
        posArgs: [ArgParser(\.app, upcastArgParserFun(parseAppArg))],
        conflictingOptions: [["--default-browser", "--default-terminal"]],
    )

    public var app: String? = nil
    public var defaultBrowser: Bool = false
    public var defaultTerminal: Bool = false
}

public enum FocusAppTarget: Equatable, Hashable, Sendable {
    /// A bundle id, or an app name
    case app(String)
    case defaultBrowser
    case defaultTerminal
}

extension FocusAppCmdArgs {
    public var target: FocusAppTarget {
        if defaultBrowser { return .defaultBrowser }
        if defaultTerminal { return .defaultTerminal }
        if let app { return .app(app) }
        die("Parser invariants are broken")
    }
}

func parseFocusAppCmdArgs(_ args: StrArrSlice) -> ParsedCmd<FocusAppCmdArgs> {
    parseSpecificCmdArgs(FocusAppCmdArgs(rawArgs: args), args)
        .filter("Specify the app: <app-bundle-id>, <app-name>, --default-browser or --default-terminal") {
            [$0.app != nil, $0.defaultBrowser, $0.defaultTerminal].count(where: { $0 }) == 1
        }
}

private func parseAppArg(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .init(i.arg.isEmpty ? .failure("The app can't be empty") : .success(i.arg), advanceBy: 1)
}
