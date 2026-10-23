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
}
