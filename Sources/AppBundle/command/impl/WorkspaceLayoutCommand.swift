import AppKit
import Common

struct WorkspaceLayoutCommand: Command {
    let args: WorkspaceLayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let current = workspace.layout
        let layouts: [WorkspaceLayout] = args.toggleBetween.val.map {
            switch $0 {
                case .layout(let layout): layout
                case .next: current.next
            }
        }
        guard let next = layouts.first(where: { $0 != current }) else {
            return .succ(io.err("Workspace '\(workspace.name)' already uses the \(current.rawValue) layout"))
        }
        workspace.layoutOverride = next
        workspace.applyLayout()
        return .succ
    }
}
