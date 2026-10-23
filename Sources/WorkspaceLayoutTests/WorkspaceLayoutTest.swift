// swift-testing rather than XCTest, so these run with the Command Line Tools alone: ./test-workspace-layouts.sh
@testable import AppBundle
import AppKit
import Common
import Testing

// The tests share the global tree and focus, so they run one at a time
@MainActor
@Suite(.serialized)
struct WorkspaceLayoutTest {
    init() {
        isUnitTest = true
        setUpWorkspacesForTests()
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

    @Test func estimatedVirtualRectMatchesLayoutRecursive() async throws {
        let workspace = Workspace.get(byName: "estimate")
        let root = workspace.rootTilingContainer
        // Weights are pixel sizes once laid out. The root's sum to the screen width; the column's don't, so
        // layoutTiles hands each of its children the same (1080 - 2) / 2 correction
        TestWindow.new(id: 1, parent: root, adaptiveWeight: 1280)
        let column = TilingContainer.newVTiles(parent: root, adaptiveWeight: 640, index: INDEX_BIND_LAST)
        TestWindow.new(id: 2, parent: column, adaptiveWeight: 1)
        let accordion = TilingContainer(parent: column, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 3, parent: accordion)
        TestWindow.new(id: 4, parent: accordion)

        for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
            #expect(window.lastAppliedLayoutVirtualRect == nil)
        }
        let estimates = Dictionary(uniqueKeysWithValues: workspace.rootTilingContainer.allLeafWindowsRecursive.map { ($0.windowId, $0.estimatedVirtualRect) })
        expectRect(estimates[1], rect(0, 0, 1280, 1080))
        expectRect(estimates[2], rect(1280, 0, 640, 540))
        expectRect(estimates[3], rect(1280, 540, 640, 540))
        expectRect(estimates[4], rect(1280, 540, 640, 540))

        try await workspace.layoutWorkspace()
        for window in workspace.rootTilingContainer.allLeafWindowsRecursive {
            let applied = try #require(window.lastAppliedLayoutVirtualRect)
            expectRect(applied, estimates[window.windowId]!, "window \(window.windowId) estimate before layout")
            expectRect(window.estimatedVirtualRect, applied, "window \(window.windowId) estimate after layout")
        }
    }
}
