@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
struct FocusAppTest {
    // MARK: Decision

    @Test func windowOnAnotherWorkspaceIsFocused() {
        #expect(focusAppAction(windows: [7], focused: 1, lastUsed: nil) == .focus(windowId: 7))
    }

    @Test func mostRecentlyUsedWindowWins() {
        #expect(focusAppAction(windows: [7, 8, 9], focused: 1, lastUsed: 8) == .focus(windowId: 8))
        #expect(focusAppAction(windows: [7, 8, 9], focused: 1, lastUsed: 42) == .focus(windowId: 7)) // last used one is gone
    }

    @Test func runningWithoutWindowsOrNotRunningOpensTheApp() {
        // LaunchServices launches an app that isn't running and sends a running one the Dock-click "reopen" event
        #expect(focusAppAction(windows: [], focused: 1, lastUsed: 8) == .open)
        #expect(focusAppAction(windows: [], focused: nil, lastUsed: nil) == .open)
    }

    @Test func pressingAgainCyclesTheAppsWindows() {
        #expect(focusAppAction(windows: [7, 8, 9], focused: 7, lastUsed: 7) == .focus(windowId: 8))
        #expect(focusAppAction(windows: [7, 8, 9], focused: 9, lastUsed: 9) == .focus(windowId: 7))
        #expect(focusAppAction(windows: [7], focused: 7, lastUsed: 7) == .stay)
    }

    // MARK: The command against real workspaces

    @Test func switchesToTheWorkspaceOfTheAppsWindowThenCyclesBetweenItsWindows() {
        let app = FakeApp(bundleId: "com.apple.Notes") // Installed on every Mac, so the target resolves
        let other = FakeApp(bundleId: "com.apple.TextEdit")
        let here = Workspace.get(byName: "focus-app-test-1")
        let there = Workspace.get(byName: "focus-app-test-4")
        let elsewhere = Workspace.get(byName: "focus-app-test-5")
        let editor = Window(id: 90_001, other, lastFloatingSize: nil, parent: here.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let notes1 = Window(id: 90_002, app, lastFloatingSize: nil, parent: there.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let notes2 = Window(id: 90_003, app, lastFloatingSize: nil, parent: elsewhere.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        defer { [editor, notes1, notes2].forEach { $0.unbindFromParent() } }
        #expect(editor.focusWindow())

        let run = { () -> BinaryExitCode in
            FocusAppCommand(args: parseCommand(["focus-app", "com.apple.Notes"]).cmdOrNil.map { ($0 as! FocusAppCommand).args }!)
                .run(.defaultEnv, CmdIoImpl(stdin: .emptyStdin))
        }
        #expect(run() == .succ)
        #expect(focus.workspace == there)
        #expect(focus.windowOrNil == notes1)

        #expect(run() == .succ)
        #expect(focus.workspace == elsewhere)
        #expect(focus.windowOrNil == notes2)

        #expect(run() == .succ)
        #expect(focus.windowOrNil == notes1)
    }

    @Test func unknownAppFails() {
        let io = CmdIoImpl(stdin: .emptyStdin)
        let args = (parseCommand(["focus-app", "no.such.app.anywhere"]).cmdOrNil as! FocusAppCommand).args
        #expect(FocusAppCommand(args: args).run(.defaultEnv, io) == .fail)
        #expect(io.stderr.first?.contains("Can't find app 'no.such.app.anywhere'") == true)
    }

    // MARK: Parsing

    @Test func parsesTargets() {
        let target = { (args: [String]) in (parseCommand(args).cmdOrNil as? FocusAppCommand)?.args.target }
        #expect(target(["focus-app", "com.google.Chrome"]) == .app("com.google.Chrome"))
        #expect(target(["focus-app", "Google Chrome"]) == .app("Google Chrome"))
        #expect(target(["focus-app", "--default-browser"]) == .defaultBrowser)
        #expect(target(["focus-app", "--default-terminal"]) == .defaultTerminal)
        #expect(parseCommand(["focus-app"]).errorOrNil?.contains("Specify the app") == true)
        #expect(parseCommand(["focus-app", "--default-browser", "Safari"]).errorOrNil != nil)
        #expect(parseCommand(["focus-app", "--default-browser", "--default-terminal"]).errorOrNil?.contains("Conflicting options") == true)
    }

    @Test func commandTextRoundTrips() {
        for target: FocusAppTarget in [.app("com.google.Chrome"), .app("Visual Studio Code"), .app("it's"), .defaultBrowser, .defaultTerminal] {
            #expect(parseFocusAppTarget(target.focusAppCommand) == target)
        }
        #expect(FocusAppTarget.app("com.google.Chrome").focusAppCommand == "focus-app com.google.Chrome")
        #expect(FocusAppTarget.defaultBrowser.focusAppCommand == "focus-app --default-browser")
    }
}

private final class FakeApp: AbstractApp {
    nonisolated(unsafe) private static var nextPid: Int32 = 900_000
    let pid: Int32
    let rawAppBundleId: String?
    let name: String? = nil
    let execPath: String? = nil
    let bundlePath: String? = nil

    init(bundleId: String) {
        Self.nextPid += 1
        pid = Self.nextPid
        rawAppBundleId = bundleId
    }

    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? { nil }
}

extension ParsedCmd {
    fileprivate var errorOrNil: String? {
        if case .failure(let failure) = self { return failure.msg }
        return nil
    }
}
