@testable import AppBundle
import AppKit
import Common
import Testing

// The scrolling layout. Same serialized suite as the other layouts: the tests share the global tree and focus
extension WorkspaceLayoutTest {
    @Test func scrollingOpensANewColumnAfterTheFocusedOne() {
        let workspace = Workspace.get(byName: "scrolling")
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        workspace.openWindow(id: 2)
        workspace.openWindow(id: 3)
        #expect(workspace.tilingWindowIds == [1, 2, 3])
        #expect(workspace.rootTilingContainer.children.map { $0.getWeight(.h) } == [960, 960, 960], "half the screen each")

        #expect(first.focusWindow())
        workspace.openWindow(id: 4)
        #expect(workspace.tilingWindowIds == [1, 4, 2, 3])
        #expect(workspace.rootTilingContainer.children.allSatisfy { $0 is Window }, "every column is a lone window so far")
        #expect(workspace.rootTilingContainer.orientation == .h)
    }

    @Test func scrollingKeepsTheFocusedColumnInViewAndParksTheRest() async throws {
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        let third = workspace.openWindow(id: 3)

        // 3 is the most recent window and the strip is 2880 wide, so it scrolls just enough to show 3
        try await workspace.layoutWorkspace()
        #expect(workspace.scrollOffset == 960)
        expectRect(first.frame, rect(-959, 0, 960, 1080), "1 is parked left with one point on screen")
        expectRect(second.frame, rect(0, 0, 960, 1080))
        expectRect(third.frame, rect(960, 0, 960, 1080))
        #expect(diagram(frames: [second, third].map { (id: $0.windowId, rect: $0.frame!) }, screen: testScreen) == """
        +-----------------------+-----------------------+
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |           2           |           3           |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        +-----------------------+-----------------------+
        """)
        expectRect(first.lastAppliedLayoutVirtualRect, rect(-960, 0, 960, 1080), "where 1 would be without parking")
        expectRect(first.lastAppliedLayoutPhysicalRect, rect(-959, 0, 960, 1080), "mouse hit-testing sees the parked frame")
        expectRect(third.lastAppliedLayoutVirtualRect, rect(960, 0, 960, 1080))

        // 2 is already in view, so focusing it moves nothing
        #expect(second.focusWindow())
        let moves = [first, second, third].map(\.setAxFrameCallCount)
        try await workspace.layoutWorkspace()
        #expect(workspace.scrollOffset == 960)
        expectRect(second.frame, rect(0, 0, 960, 1080))
        expectRect(third.frame, rect(960, 0, 960, 1080))
        #expect([first, second, third].map(\.setAxFrameCallCount) == moves.map { $0 + 1 }, "one setAxFrame per window per pass, to the same frames")

        // 1 is left of the viewport: the strip scrolls back to the start and 3 gets parked right
        #expect(first.focusWindow())
        try await workspace.layoutWorkspace()
        #expect(workspace.scrollOffset == 0)
        expectRect(first.frame, rect(0, 0, 960, 1080))
        expectRect(second.frame, rect(960, 0, 960, 1080))
        expectRect(third.frame, rect(1919, 0, 960, 1080), "3 is parked right with one point on screen")
        expectRect(third.lastAppliedLayoutVirtualRect, rect(1920, 0, 960, 1080))
        #expect(diagram(frames: [first, second].map { (id: $0.windowId, rect: $0.frame!) }, screen: testScreen) == """
        +-----------------------+-----------------------+
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |           1           |           2           |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        |                       |                       |
        +-----------------------+-----------------------+
        """)
    }
}
