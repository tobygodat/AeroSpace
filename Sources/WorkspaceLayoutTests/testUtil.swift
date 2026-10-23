@testable import AppBundle
import AppKit
import Common
import Testing

/// Modeled on Sources/AppBundleTests/testUtil.swift: a fresh config and a single empty focused workspace
@MainActor
func setUpWorkspacesForTests() {
    config = defaultConfig
    configUrl = defaultConfigUrl
    config.enableNormalizationFlattenContainers = false
    config.enableNormalizationOppositeOrientationForNestedContainers = false
    config.defaultRootContainerOrientation = .horizontal

    config.modes = [mainModeId: Mode(bindings: [:])]
    config.persistentWorkspaces = []

    for workspace in Workspace.all {
        workspace.layoutOverride = nil
        workspace.windowsFloatedByLayout = []
        for child in workspace.children {
            child.unbindFromParent()
        }
    }
    check(Workspace.get(byName: "setUpWorkspacesForTests").focusWorkspace())
    Workspace.garbageCollectUnusedWorkspaces()
    check(focus.workspace.isEffectivelyEmpty)
    check(focus.workspace === Workspace.all.singleOrNil(), Workspace.all.map(\.description).joined(separator: ", "))
    check(mainMonitor.setActiveWorkspace(focus.workspace))

    TestApp.shared.focusedWindow = nil
    TestApp.shared.windows = []
}

/// Runs a command line the way a keybinding would, refresh included
@MainActor
func run(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    guard let parsed = parseCommand(command, allowExecAndForget: false, allowEval: false).cmdOrNil else {
        Issue.record("'\(command)' doesn't parse", sourceLocation: sourceLocation)
        return
    }
    let result = await parsed.run(.defaultEnv, .emptyStdin)
    #expect(result.exitCode.rawValue == 0, "'\(command)' failed: \(result.stderr)", sourceLocation: sourceLocation)
}

extension Workspace {
    /// What MacWindow.getOrRegister does for a window that just appeared on this workspace: the policy picks
    /// the parent, then the window is created there. `bind` makes it the most recent window
    @discardableResult
    @MainActor
    func openWindow(id: UInt32) -> TestWindow {
        let data = bindingDataForNewTilingWindow(windowId: id, window: nil)
        return TestWindow.new(id: id, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
    }

    /// Every tiling window's last applied frame, by window id
    @MainActor
    var tilingFrames: [(id: UInt32, rect: Rect)] {
        rootTilingContainer.allLeafWindowsRecursive
            .sortedBy(\.windowId)
            .map { (id: $0.windowId, rect: ($0 as! TestWindow).frame.orDie("\($0) was never laid out")) }
    }

    @MainActor
    var tilingWindowIds: [UInt32] { rootTilingContainer.allLeafWindowsRecursive.map(\.windowId) }

    @MainActor
    var floatingWindowIds: [UInt32] { floatingWindows.map(\.windowId) }
}

extension Rect {
    /// layoutWorkspace lays out with `height - 1`, so frames are compared with a 1 pt tolerance
    func isClose(to other: Rect) -> Bool {
        abs(topLeftX - other.topLeftX) <= 1 && abs(topLeftY - other.topLeftY) <= 1 &&
            abs(width - other.width) <= 1 && abs(height - other.height) <= 1
    }
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Rect {
    Rect(topLeftX: x, topLeftY: y, width: w, height: h)
}

/// The unit-test monitor (Sources/AppBundle/model/Monitor.swift)
let testScreen = rect(0, 0, 1920, 1080)

func expectRect(_ actual: Rect?, _ expected: Rect, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    let message = "\(comment.map { "\($0): " } ?? "")expected \(expected), got \(actual.map { "\($0)" } ?? "nil")"
    #expect(actual?.isClose(to: expected) == true, Comment(rawValue: message), sourceLocation: sourceLocation)
}

/// Draws every frame as a box labelled with its window id on a `columns` x `rows` grid that covers `screen`.
/// Boxes that share an edge share a border line, so the picture reads like the tiled screen
func diagram(frames: [(id: UInt32, rect: Rect)], screen: Rect, columns: Int = 48, rows: Int = 12) -> String {
    var canvas = Array(repeating: Array(repeating: Character(" "), count: columns + 1), count: rows + 1)
    func col(_ x: CGFloat) -> Int { Int(((x - screen.minX) / screen.width * CGFloat(columns)).rounded()) }
    func row(_ y: CGFloat) -> Int { Int(((y - screen.minY) / screen.height * CGFloat(rows)).rounded()) }
    for (id, rect) in frames {
        let (left, right, top, bottom) = (col(rect.minX), col(rect.maxX), row(rect.minY), row(rect.maxY))
        for x in left ... right {
            canvas[top][x] = "-"
            canvas[bottom][x] = "-"
        }
        for y in top ... bottom {
            canvas[y][left] = "|"
            canvas[y][right] = "|"
        }
        for (x, y) in [(left, top), (right, top), (left, bottom), (right, bottom)] {
            canvas[y][x] = "+"
        }
        let label = Array(String(id))
        let labelLeft = (left + right) / 2 - label.count / 2
        for (i, char) in label.enumerated() {
            canvas[(top + bottom) / 2][labelLeft + i] = char
        }
    }
    return canvas.map { String($0) }.joined(separator: "\n")
}
