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
        let editor = window(90_001, other, here.rootTilingContainer)
        let notes1 = window(90_002, app, there.rootTilingContainer)
        let notes2 = window(90_003, app, elsewhere.rootTilingContainer)
        defer { cleanUp(editor, notes1, notes2) }
        #expect(editor.focusWindow())
        appForTests = other

        #expect(pressFocusApp("com.apple.Notes") == .succ)
        #expect(focus.workspace == there)
        #expect(focus.windowOrNil == notes1)

        #expect(pressFocusApp("com.apple.Notes") == .succ)
        #expect(focus.workspace == elsewhere)
        #expect(focus.windowOrNil == notes2)

        #expect(pressFocusApp("com.apple.Notes") == .succ)
        #expect(focus.windowOrNil == notes1)
    }

    @Test func bringsTheAppForwardWhenAeroSpaceFocusIsAlreadyOnIt() {
        let app = FakeApp(bundleId: "com.apple.Notes")
        let notes = window(90_011, app, Workspace.get(byName: "focus-app-test-6").rootTilingContainer)
        defer { cleanUp(notes) }
        #expect(notes.focusWindow())
        // AeroSpace's own settings window is in front. AeroSpace doesn't manage it, so its focus stays on Notes
        appForTests = FakeApp(bundleId: "bobko.aerospace")

        #expect(pressFocusApp("com.apple.Notes") == .succ)
        #expect(notes.nativeFocusCount == 1)
        #expect(appForTests?.pid == app.pid)

        #expect(pressFocusApp("com.apple.Notes") == .succ) // In front now, with one window: nothing to do
        #expect(notes.nativeFocusCount == 1)
    }

    @Test func goesToTheMostRecentlyUsedWindowOfAnyInstanceOfTheApp() {
        let instance1 = FakeApp(bundleId: "com.apple.Notes")
        let instance2 = FakeApp(bundleId: "com.apple.Notes")
        let other = FakeApp(bundleId: "com.apple.TextEdit")
        let editor = window(90_021, other, Workspace.get(byName: "focus-app-test-1").rootTilingContainer)
        let older = window(90_022, instance1, Workspace.get(byName: "focus-app-test-4").rootTilingContainer)
        let newer = window(90_023, instance2, Workspace.get(byName: "focus-app-test-5").rootTilingContainer)
        defer { cleanUp(editor, older, newer) }
        older.lastNativeFocus = 3
        newer.lastNativeFocus = 7
        editor.lastNativeFocus = 9
        #expect(editor.focusWindow())
        appForTests = other

        #expect(pressFocusApp("com.apple.Notes") == .succ)
        #expect(focus.windowOrNil == newer)
    }

    @Test func windowOfAHiddenAppIsFocusedOnItsWorkspace() {
        let app = FakeApp(bundleId: "com.apple.Notes")
        let other = FakeApp(bundleId: "com.apple.TextEdit")
        let there = Workspace.get(byName: "focus-app-test-4")
        let editor = window(90_031, other, Workspace.get(byName: "focus-app-test-1").rootTilingContainer)
        let notes = window(90_032, app, there.macOsNativeHiddenAppsWindowsContainer)
        defer { cleanUp(editor, notes) }
        #expect(editor.focusWindow())
        appForTests = other

        #expect(pressFocusApp("com.apple.Notes") == .succ)
        #expect(focus.workspace == there)
        #expect(focus.windowOrNil == notes)
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

/// Runs the command, then lets macOS follow AeroSpace's focus the way the session after a hotkey does
@MainActor
private func pressFocusApp(_ app: String) -> BinaryExitCode {
    let args = (parseCommand(["focus-app", app]).cmdOrNil as! FocusAppCommand).args
    let result = FocusAppCommand(args: args).run(.defaultEnv, CmdIoImpl(stdin: .emptyStdin))
    appForTests = focus.windowOrNil?.app
    return result
}

@MainActor
private func window(_ id: UInt32, _ app: FakeApp, _ parent: NonLeafTreeNodeObject) -> FakeWindow {
    FakeWindow(id: id, app, lastFloatingSize: nil, parent: parent, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
}

@MainActor
private func cleanUp(_ windows: Window...) {
    windows.forEach { $0.unbindFromParent() }
    appForTests = nil
}

private final class FakeWindow: Window {
    var nativeFocusCount = 0

    @MainActor override func nativeFocus() {
        nativeFocusCount += 1
        appForTests = app
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
