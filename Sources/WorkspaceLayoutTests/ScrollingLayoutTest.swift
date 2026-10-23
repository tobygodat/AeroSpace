@testable import AppBundle
import AppKit
import Common
import Testing

// The scrolling layout. Same serialized suite as the other layouts: the tests share the global tree and focus
/// Where an out-of-view column goes on the 1920x1080 test monitor: the bottom-right corner, one point on screen
private let parked = rect(1919, 1079, 960, 1080)

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
        expectRect(first.frame, parked, "1 is parked in the bottom-right corner with one point on screen")
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
        expectRect(first.lastAppliedLayoutPhysicalRect, parked, "mouse hit-testing sees the parked frame")
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
        expectRect(third.frame, parked, "3 is parked with one point on screen")
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

    @Test func scrollingColumnsAreAnInnerGapApart() async throws {
        config.gaps.inner.horizontal = .constant(10)
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        let third = workspace.openWindow(id: 3)

        #expect(first.focusWindow())
        try await workspace.layoutWorkspace()
        #expect(workspace.scrollOffset == 0)
        expectRect(first.frame, rect(0, 0, 960, 1080))
        expectRect(second.frame, rect(970, 0, 960, 1080), "a gap after 1")
        expectRect(third.frame, parked, "3 starts at 1940, past the screen, so it is parked")

        // The strip is 2900 wide, so showing 3 scrolls by 980 and cuts the gap's worth off 2
        #expect(third.focusWindow())
        try await workspace.layoutWorkspace()
        #expect(workspace.scrollOffset == 980)
        expectRect(first.frame, parked)
        expectRect(second.frame, rect(-10, 0, 960, 1080), "2 overlaps the screen, so it is laid out where it is rather than parked")
        expectRect(third.frame, rect(960, 0, 960, 1080))
    }

    @Test func scrollingGivesAnUnsizedColumnTheDefaultWidthAndCapsAColumnAtTheScreen() async throws {
        let workspace = Workspace.get(byName: "scrolling")
        workspace.layoutOverride = .scrolling
        // What `move` does when it expels a window into an empty root: WEIGHT_AUTO with no siblings is weight 1
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: 3000)
        #expect(first.getWeight(.h) == 1)

        try await workspace.layoutWorkspace()
        #expect(workspace.rootTilingContainer.children.map { $0.getWeight(.h) } == [960, 3000], "the unsized column is sized now; the wide one keeps its weight for a wider screen")
        #expect(workspace.scrollOffset == 960, "2 is focused and as wide as the screen")
        expectRect(first.frame, parked)
        expectRect(second.frame, rect(0, 0, 1920, 1080))
    }

    @Test func joinWithStacksIntoAColumnAndMoveWalksTheStrip() async throws {
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        let third = workspace.openWindow(id: 3)

        #expect(first.focusWindow())
        await run("move right")
        #expect(workspace.tilingWindowIds == [2, 1, 3], "two lone columns swap")
        #expect(workspace.rootTilingContainer.children.map { $0.getWeight(.h) } == [960, 960, 960])

        #expect(third.focusWindow())
        await run("join-with left")
        let column = try #require(workspace.rootTilingContainer.children[1] as? TilingContainer)
        #expect(column.orientation == .v)
        #expect(column.children == [first, third])
        #expect(column.getWeight(.h) == 960, "the column keeps the width of the window it replaced")
        try await workspace.layoutWorkspace()
        #expect(workspace.scrollOffset == 0)
        expectRect(second.frame, rect(0, 0, 960, 1080))
        expectRect(first.frame, rect(960, 0, 960, 540))
        expectRect(third.frame, rect(960, 540, 960, 540))
        #expect(diagram(frames: workspace.tilingFrames, screen: testScreen) == """
        +-----------------------+-----------------------+
        |                       |                       |
        |                       |                       |
        |                       |           1           |
        |                       |                       |
        |                       |                       |
        |           2           +-----------------------+
        |                       |                       |
        |                       |                       |
        |                       |           3           |
        |                       |                       |
        |                       |                       |
        +-----------------------+-----------------------+
        """)

        #expect(first.focusWindow())
        let stderr = await run("move up", expectSuccess: false)
        #expect(stderr.first?.contains("scrolling layout has no rows") == true, "\(stderr)")
        #expect(column.children == [first, third], "nothing moved")

        #expect(second.focusWindow())
        await run("move right")
        #expect(workspace.rootTilingContainer.children == [column], "2 joins the column next to it")
        #expect(column.children == [first, second, third], "after the column's most recent window")

        await run("move left")
        #expect(workspace.tilingWindowIds == [2, 1, 3], "and leaves it as a column of its own")
        #expect(workspace.rootTilingContainer.children.first === second)
        await run("move left")
        #expect(workspace.rootTilingContainer.children.first === second, "the first column stays the first column: the strip is never wrapped")
        #expect(workspace.rootTilingContainer.parent is Workspace)
        try await workspace.layoutWorkspace()
        expectRect(second.frame, rect(0, 0, 960, 1080), "a column expelled with WEIGHT_AUTO takes the width of its neighbours")
        expectRect(first.frame, rect(960, 0, 960, 540))

        // Closing a stacked window flattens the column to the window that is left, at the column's width
        config.enableNormalizationFlattenContainers = true
        third.closeAxWindow()
        workspace.normalizeContainers()
        #expect(workspace.rootTilingContainer.children == [second, first])
        #expect(first.getWeight(.h) == 960)
    }

    @Test func switchingToAndFromScrollingRebuildsTheColumns() async throws {
        let workspace = Workspace.get(byName: "switch")
        #expect(workspace.focusWorkspace())
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        let third = workspace.openWindow(id: 3)
        try await workspace.layoutWorkspace()
        expectRect(third.frame, rect(1280, 0, 640, 1080), "tiles: three equal columns")

        #expect(first.focusWindow())
        await run("workspace-layout scrolling")
        #expect(workspace.scrollOffset == 0)
        #expect(workspace.tilingWindowIds == [1, 2, 3])
        #expect(workspace.rootTilingContainer.children.map { $0.getWeight(.h) } == [960, 960, 960])
        try await workspace.layoutWorkspace()
        expectRect(first.frame, rect(0, 0, 960, 1080))
        expectRect(second.frame, rect(960, 0, 960, 1080))
        expectRect(third.frame, parked, "parked")

        #expect(third.focusWindow())
        await run("join-with left")
        #expect(workspace.rootTilingContainer.children.count == 2)
        await run("workspace-layout dwindle")
        #expect(workspace.tilingWindowIds == [1, 2, 3])
        try await workspace.layoutWorkspace()
        expectRect(first.frame, rect(0, 0, 960, 1080), "dwindle: the spiral")
        expectRect(second.frame, rect(960, 0, 960, 540))
        expectRect(third.frame, rect(960, 540, 960, 540))

        await run("workspace-layout scrolling")
        #expect(workspace.rootTilingContainer.children.allSatisfy { $0 is Window }, "the spiral's container is gone")
        #expect(workspace.rootTilingContainer.children.map { $0.getWeight(.h) } == [960, 960, 960])

        #expect(third.focusWindow())
        await run("join-with left")
        await run("workspace-layout tiles")
        #expect(workspace.tilingWindowIds == [1, 2, 3])
        #expect(workspace.rootTilingContainer.children.allSatisfy { $0 is Window }, "the column container is gone")
        try await workspace.layoutWorkspace()
        expectRect(first.frame, rect(0, 0, 640, 1080), "tiles again")
        expectRect(third.frame, rect(1280, 0, 640, 1080))
    }

    @Test func theStripStaysAHorizontalRowOfColumns() async throws {
        // A lone column is a direct child of the root, so `layout accordion` or `layout vertical` on it would hit the root
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        #expect(second.focusWindow())
        let stderr = await run("layout accordion", expectSuccess: false)
        #expect(stderr.first?.contains("join-with") == true, "\(stderr)")
        await run("layout vertical", expectSuccess: false)
        await run("layout --root accordion", expectSuccess: false)
        #expect(workspace.rootTilingContainer.layout == .tiles && workspace.rootTilingContainer.orientation == .h)

        // A column of its own can be an accordion
        await run("join-with left")
        await run("layout accordion")
        let column = try #require(workspace.rootTilingContainer.children.first as? TilingContainer)
        #expect(column.layout == .accordion && column.orientation == .v)
        #expect(workspace.rootTilingContainer.layout == .tiles && workspace.rootTilingContainer.orientation == .h)

        // With the stock normalization on, a strip of one column keeps its root rather than becoming that column
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        workspace.normalizeContainers()
        #expect(workspace.rootTilingContainer.children == [column], "the strip is not flattened into its only column")
        try await workspace.layoutWorkspace()
        #expect(first.frame?.minX == 0 && first.frame?.width == 960, "the column keeps its width; the accordion pads its tabs vertically")
        #expect(second.frame?.width == 960)
    }

    @Test func resizeWidthChangesOneColumnOnly() async throws {
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        try await workspace.layoutWorkspace()
        #expect(second.focusWindow())

        await run("resize width 1200")
        try await workspace.layoutWorkspace()
        #expect(workspace.scrollOffset == 240, "the strip is 2160 wide now and 2 is focused")
        expectRect(first.frame, rect(-240, 0, 960, 1080), "1 keeps its width and peeks in from the left")
        expectRect(second.frame, rect(720, 0, 1200, 1080))

        await run("resize width -2000")
        try await workspace.layoutWorkspace()
        #expect(second.frame?.width == 192, "no narrower than the smallest scrolling-column-width")
        await run("resize width +5000")
        try await workspace.layoutWorkspace()
        #expect(second.frame?.width == 1920, "no wider than the screen")

        #expect(first.focusWindow())
        await run("resize width 300")
        try await workspace.layoutWorkspace()
        expectRect(first.frame, rect(0, 0, 300, 1080), "a single column resizes too, and nothing else changed")
        expectRect(second.frame, rect(300, 0, 1920, 1080))
    }

    @Test func leavingScrollingForFloatingPullsParkedColumnsOnScreen() async throws {
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        let third = workspace.openWindow(id: 3)
        try await workspace.layoutWorkspace()
        expectRect(first.frame, parked)

        await run("workspace-layout floating")
        try await workspace.layoutWorkspace()
        #expect(workspace.floatingWindowIds == [1, 2, 3])
        expectRect(first.frame, rect(960, 0, 960, 1080), "1 comes back where the strip had it, pulled onto the screen")
        expectRect(second.frame, rect(0, 0, 960, 1080), "2 and 3 float where they stood")
        expectRect(third.frame, rect(960, 0, 960, 1080))
    }

    @Test func disablingTheWindowManagerLeavesNoColumnParked() async throws {
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        workspace.openWindow(id: 2)
        workspace.openWindow(id: 3)
        try await workspace.layoutWorkspace()
        expectRect(first.frame, parked)

        TrayMenuModel.shared.isEnabled = false
        defer { TrayMenuModel.shared.isEnabled = true }
        try await workspace.layoutWorkspace()
        expectRect(first.frame, rect(0, 0, 960, 1080), "reachable, at the edge it would scroll in from")
    }

    @Test func fullscreenWinsTheWholeScreenInAScrollingWorkspace() async throws {
        let workspace = Workspace.get(byName: "scrolling")
        #expect(workspace.focusWorkspace())
        workspace.layoutOverride = .scrolling
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        let third = workspace.openWindow(id: 3)

        #expect(second.focusWindow())
        second.isFullscreen = true
        third.isFullscreen = true
        try await workspace.layoutWorkspace()
        expectRect(second.frame, rect(0, 0, 1920, 1080))
        #expect(second.lastAppliedLayoutPhysicalRect == nil, "as layoutRecursive records a fullscreen window")
        expectRect(first.frame, rect(0, 0, 960, 1080), "the other columns stay where the strip puts them")
        expectRect(third.frame, parked)
        #expect(!third.isFullscreen, "only the focused window can be fullscreen")

        #expect(first.focusWindow())
        try await workspace.layoutWorkspace()
        #expect(!second.isFullscreen)
        expectRect(second.frame, rect(960, 0, 960, 1080))
    }
}
