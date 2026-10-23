// swift-testing rather than XCTest, so these run with the Command Line Tools alone: ./test-workspace-layouts.sh
@testable import AppBundle
import AppKit
import Common
import Testing

@MainActor
struct WorkspaceLayoutTest {
    init() {
        isUnitTest = true
    }

    @Test func layoutCyclesThroughEveryMode() {
        var seen: [WorkspaceLayout] = []
        var layout = WorkspaceLayout.tiles
        for _ in WorkspaceLayout.allCases {
            seen.append(layout)
            layout = layout.next
        }
        #expect(seen == WorkspaceLayout.allCases)
        #expect(layout == .tiles)
    }

    @Test func commandParses() {
        #expect(parseCommand("workspace-layout dwindle", allowExecAndForget: false, allowEval: false).cmdOrNil != nil)
        #expect(parseCommand("workspace-layout next", allowExecAndForget: false, allowEval: false).cmdOrNil != nil)
        #expect(parseCommand("workspace-layout --workspace 2 tiles floating", allowExecAndForget: false, allowEval: false).cmdOrNil != nil)
        #expect(parseCommand("workspace-layout next tiles", allowExecAndForget: false, allowEval: false).cmdOrNil == nil)
        #expect(parseCommand("workspace-layout spiral", allowExecAndForget: false, allowEval: false).cmdOrNil == nil)
    }
}
