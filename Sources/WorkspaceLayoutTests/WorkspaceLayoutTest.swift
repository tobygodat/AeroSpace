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

    @Test func tilesPolicyBindsNextToTheMostRecentWindow() {
        let workspace = Workspace.get(byName: "tiles")
        #expect(workspace.layout == .tiles)
        let first = workspace.openWindow(id: 1)
        workspace.openWindow(id: 2)
        workspace.openWindow(id: 3)
        #expect(workspace.tilingWindowIds == [1, 2, 3])

        #expect(first.focusWindow())
        workspace.openWindow(id: 4)
        #expect(workspace.tilingWindowIds == [1, 4, 2, 3])
        #expect(workspace.rootTilingContainer.children.count == 4, "tiles never nests on its own")
    }

    @Test func dwindleSplitsTheMostRecentWindowAlongItsLongerSide() async throws {
        let workspace = Workspace.get(byName: "dwindle")
        workspace.layoutOverride = .dwindle

        workspace.openWindow(id: 1)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[0].rect, rect(0, 0, 1920, 1080))

        workspace.openWindow(id: 2)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[0].rect, rect(0, 0, 960, 1080))
        expectRect(workspace.tilingFrames[1].rect, rect(960, 0, 960, 1080))

        workspace.openWindow(id: 3)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[1].rect, rect(960, 0, 960, 540), "2 keeps the top of its column")
        expectRect(workspace.tilingFrames[2].rect, rect(960, 540, 960, 540), "3 takes the bottom of 2's column")

        workspace.openWindow(id: 4)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[2].rect, rect(960, 540, 480, 540))
        expectRect(workspace.tilingFrames[3].rect, rect(1440, 540, 480, 540), "4 takes the right half of 3's cell")

        workspace.openWindow(id: 5)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[0].rect, rect(0, 0, 960, 1080))
        expectRect(workspace.tilingFrames[1].rect, rect(960, 0, 960, 540))
        expectRect(workspace.tilingFrames[2].rect, rect(960, 540, 480, 540))
        expectRect(workspace.tilingFrames[3].rect, rect(1440, 540, 480, 270))
        expectRect(workspace.tilingFrames[4].rect, rect(1440, 810, 480, 270), "5 takes the bottom half of 4's cell")
        #expect(diagram(frames: workspace.tilingFrames, screen: testScreen) == """
        +-----------------------+-----------------------+
        |                       |                       |
        |                       |                       |
        |                       |           2           |
        |                       |                       |
        |                       |                       |
        |           1           +-----------+-----------+
        |                       |           |     4     |
        |                       |           |           |
        |                       |     3     +-----------+
        |                       |           |     5     |
        |                       |           |           |
        +-----------------------+-----------+-----------+
        """)
    }

    @Test func dwindleFollowsFocus() async throws {
        let workspace = Workspace.get(byName: "dwindle")
        workspace.layoutOverride = .dwindle
        let first = workspace.openWindow(id: 1)
        workspace.openWindow(id: 2)
        workspace.openWindow(id: 3)
        try await workspace.layoutWorkspace()

        #expect(first.focusWindow())
        workspace.openWindow(id: 4)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[0].rect, rect(0, 0, 960, 540), "1's cell is taller than wide, so it splits top/bottom")
        expectRect(workspace.tilingFrames[3].rect, rect(0, 540, 960, 540))
        expectRect(workspace.tilingFrames[1].rect, rect(960, 0, 960, 540), "2 is untouched")
        expectRect(workspace.tilingFrames[2].rect, rect(960, 540, 960, 540), "3 is untouched")
        #expect(diagram(frames: workspace.tilingFrames, screen: testScreen) == """
        +-----------------------+-----------------------+
        |                       |                       |
        |                       |                       |
        |           1           |           2           |
        |                       |                       |
        |                       |                       |
        +-----------------------+-----------------------+
        |                       |                       |
        |                       |                       |
        |           4           |           3           |
        |                       |                       |
        |                       |                       |
        +-----------------------+-----------------------+
        """)
    }

    @Test func closingADwindleWindowGivesItsCellBack() async throws {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: "dwindle")
        workspace.layoutOverride = .dwindle
        workspace.openWindow(id: 1)
        workspace.openWindow(id: 2)
        let third = workspace.openWindow(id: 3)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[1].rect, rect(960, 0, 960, 540))

        third.closeAxWindow()
        workspace.normalizeContainers()
        try await workspace.layoutWorkspace()
        #expect(workspace.tilingWindowIds == [1, 2])
        expectRect(workspace.tilingFrames[1].rect, rect(960, 0, 960, 1080), "2 is back to the full right half")
        #expect(workspace.rootTilingContainer.children.allSatisfy { $0 is Window }, "the empty column is gone")

        workspace.openWindow(id: 4)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[2].rect, rect(960, 540, 960, 540), "the next window splits 2 again")
    }

    @Test func floatingLayoutFloatsTheTiledWindowsInPlaceAndTilesThemBack() async throws {
        let workspace = Workspace.get(byName: "floating")
        #expect(workspace.focusWorkspace())
        let dialog = TestWindow.new(id: 0, parent: workspace.floatingWindowsContainer, frame: rect(100, 100, 400, 300))
        let first = workspace.openWindow(id: 1)
        let second = workspace.openWindow(id: 2)
        try await workspace.layoutWorkspace()
        let tiledFrames = [first.frame, second.frame]
        let moves = [first.setAxFrameCallCount, second.setAxFrameCallCount]

        workspace.layoutOverride = .floating
        workspace.applyLayout(.floating)
        try await workspace.layoutWorkspace()
        #expect(workspace.floatingWindowIds == [0, 1, 2])
        #expect(workspace.tilingWindowIds == [])
        #expect(workspace.windowsFloatedByLayout == [1, 2], "the dialog floated on its own, so it isn't recorded")
        expectRect(first.frame, tiledFrames[0]!, "1 keeps the frame it had as a tile")
        expectRect(second.frame, tiledFrames[1]!, "2 keeps the frame it had as a tile")
        #expect([first.setAxFrameCallCount, second.setAxFrameCallCount] == moves, "nothing moved the windows")
        #expect(first.lastFloatingSize == tiledFrames[0]!.size)

        let third = workspace.openWindow(id: 3)
        #expect(third.isFloating)
        #expect(workspace.windowsFloatedByLayout == [1, 2, 3])

        workspace.layoutOverride = .tiles
        workspace.applyLayout(.tiles)
        try await workspace.layoutWorkspace()
        #expect(workspace.tilingWindowIds == [1, 2, 3])
        #expect(workspace.floatingWindowIds == [0], "the dialog still floats")
        #expect(workspace.windowsFloatedByLayout == [])
        expectRect(dialog.frame, rect(100, 100, 400, 300))
        expectRect(first.frame, rect(0, 0, 640, 1080))
        expectRect(third.frame, rect(1280, 0, 640, 1080))
    }

    @Test func switchingTilesToDwindleRebuildsTheSpiralAndBackFlattens() async throws {
        let workspace = Workspace.get(byName: "switch")
        let first = workspace.openWindow(id: 1)
        workspace.openWindow(id: 2)
        workspace.openWindow(id: 3)
        workspace.openWindow(id: 4)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[3].rect, rect(1440, 0, 480, 1080), "tiles: four columns")

        workspace.layoutOverride = .dwindle
        workspace.applyLayout(.dwindle)
        try await workspace.layoutWorkspace()
        #expect(diagram(frames: workspace.tilingFrames, screen: testScreen) == """
        +-----------------------+-----------------------+
        |                       |                       |
        |                       |                       |
        |                       |           2           |
        |                       |                       |
        |                       |                       |
        |           1           +-----------+-----------+
        |                       |           |           |
        |                       |           |           |
        |                       |     3     |     4     |
        |                       |           |           |
        |                       |           |           |
        +-----------------------+-----------+-----------+
        """)

        #expect(first.focusWindow())
        workspace.openWindow(id: 5)
        #expect(workspace.tilingWindowIds == [1, 5, 2, 3, 4], "depth-first order of the spiral")

        workspace.layoutOverride = .tiles
        workspace.applyLayout(.tiles)
        try await workspace.layoutWorkspace()
        #expect(workspace.tilingWindowIds == [1, 5, 2, 3, 4], "flattened in depth-first order")
        #expect(workspace.rootTilingContainer.children.allSatisfy { $0 is Window })
        for (column, window) in workspace.rootTilingContainer.allLeafWindowsRecursive.enumerated() {
            expectRect((window as! TestWindow).frame, rect(CGFloat(column) * 384, 0, 384, 1080), "window \(window.windowId) is column \(column)")
        }
    }

    @Test func workspaceLayoutCommandSwitchesAndCyclesLayouts() async throws {
        let workspace = Workspace.get(byName: "cmd")
        #expect(workspace.focusWorkspace())
        for id: UInt32 in 1 ... 4 { workspace.openWindow(id: id) }
        try await workspace.layoutWorkspace()

        await run("workspace-layout dwindle")
        #expect(workspace.layoutOverride == .dwindle)
        try await workspace.layoutWorkspace()
        expectRect(workspace.tilingFrames[3].rect, rect(1440, 540, 480, 540), "rebuilt as a spiral")

        await run("workspace-layout tiles dwindle")
        #expect(workspace.layout == .tiles, "the first target the workspace isn't in wins")
        #expect(workspace.rootTilingContainer.children.allSatisfy { $0 is Window })
        await run("workspace-layout tiles dwindle")
        #expect(workspace.layout == .dwindle)

        await run("workspace-layout next")
        #expect(workspace.layout == .floating)
        #expect(workspace.floatingWindowIds == [1, 2, 3, 4])
        await run("workspace-layout next")
        #expect(workspace.layout == .tiles)
        #expect(workspace.tilingWindowIds == [1, 2, 3, 4])
        #expect(workspace.floatingWindowIds == [])
        await run("workspace-layout next")
        #expect(workspace.layout == .dwindle)

        let other = Workspace.get(byName: "other")
        other.openWindow(id: 9)
        await run("workspace-layout --workspace other floating")
        #expect(other.layout == .floating)
        #expect(other.floatingWindowIds == [9])
        #expect(workspace.layout == .dwindle, "the focused workspace is left alone")
        #expect(focus.workspace == workspace)
    }

    @Test func configDeclaresTheDefaultAndPerWorkspaceLayouts() {
        let parsed = parseConfig("""
        default-workspace-layout = 'dwindle'
        [workspace-layout]
        2 = 'floating'
        """)
        #expect(parsed.errors.isEmpty, "\(parsed.errors.map { $0.description(.error) })")
        #expect(parsed.config.defaultWorkspaceLayout == .dwindle)
        #expect(parsed.config.workspaceLayouts == ["2": .floating])

        let unknown = parseConfig("default-workspace-layout = 'spiral'")
        #expect(unknown.errors.count == 1)
        #expect(unknown.errors.first?.description(.error).contains(WorkspaceLayout.unionLiteral) == true, "\(unknown.errors.map { $0.description(.error) })")
        #expect(parseConfig("[workspace-layout]\n2 = 'spiral'").errors.count == 1)

        config = parsed.config
        let second = Workspace.get(byName: "2")
        #expect(Workspace.get(byName: "1").layout == .dwindle, "default")
        #expect(second.layout == .floating, "the table beats the default")
        second.layoutOverride = .tiles
        #expect(second.layout == .tiles, "the command beats the table")
    }

    @Test func reloadingTheConfigDropsOverridesAndRebuildsChangedWorkspaces() async throws {
        let changed = Workspace.get(byName: "changed")
        for id: UInt32 in 1 ... 4 { changed.openWindow(id: id) }
        changed.layoutOverride = .floating
        changed.applyLayout(.floating)
        let same = Workspace.get(byName: "same")
        same.layoutOverride = .dwindle
        for id: UInt32 in 1 ... 3 { same.openWindow(id: id + 10) }
        let column = same.rootTilingContainer.children[1]

        // ReloadConfigCommand's sequence: remember the effective layouts, swap the config, sync
        let before = Workspace.all.map { (workspace: $0, layout: $0.layout) }
        config.defaultWorkspaceLayout = .dwindle
        syncWorkspaceLayoutsAfterConfigReload(layoutsBeforeReload: before)

        #expect(changed.layoutOverride == nil)
        #expect(changed.layout == .dwindle)
        #expect(changed.tilingWindowIds == [1, 2, 3, 4])
        #expect(changed.windowsFloatedByLayout == [])
        try await changed.layoutWorkspace()
        expectRect(changed.tilingFrames[3].rect, rect(1440, 540, 480, 540), "tiled back as a spiral")

        #expect(same.layoutOverride == nil)
        #expect(same.layout == .dwindle)
        #expect(same.rootTilingContainer.children[1] === column, "an unchanged layout leaves the tree alone")
    }

    @Test func movingAWindowIntoANonTilesWorkspaceUsesThatWorkspacesPolicy() async throws {
        let source = Workspace.get(byName: "source")
        let moved = source.openWindow(id: 9)
        let dwindle = Workspace.get(byName: "dwindle")
        dwindle.layoutOverride = .dwindle
        dwindle.openWindow(id: 1)
        dwindle.openWindow(id: 2)
        try await dwindle.layoutWorkspace()

        #expect(moveWindowToWorkspace(moved, dwindle, CmdIoImpl.emptyStdinIgnoringOut, focusFollowsWindow: false, failIfNoop: false) == .succ)
        try await dwindle.layoutWorkspace()
        #expect(source.isEffectivelyEmpty)
        #expect(dwindle.tilingWindowIds == [1, 2, 9])
        expectRect(dwindle.tilingFrames[1].rect, rect(960, 0, 960, 540), "2 was the most recent window, so it got split")
        expectRect(dwindle.tilingFrames[2].rect, rect(960, 540, 960, 540))

        let floating = Workspace.get(byName: "floating")
        floating.layoutOverride = .floating
        #expect(moveWindowToWorkspace(moved, floating, CmdIoImpl.emptyStdinIgnoringOut, focusFollowsWindow: false, failIfNoop: false) == .succ)
        #expect(moved.isFloating)
        #expect(floating.floatingWindowIds == [9])
        #expect(floating.windowsFloatedByLayout == [9])
        #expect(dwindle.tilingWindowIds == [1, 2])
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
