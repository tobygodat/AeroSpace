@testable import AppBundle
import AppKit

/// A window double that remembers the last frame layoutRecursive handed it, so a test can assert what the user
/// would see without AX
final class TestWindow: Window, CustomStringConvertible {
    /// The frame as the last `setAxFrame` left it. nil until the first layout pass
    private(set) var frame: Rect?
    private(set) var setAxFrameCallCount = 0

    @MainActor
    private init(_ id: UInt32, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ index: Int, _ frame: Rect?) {
        self.frame = frame
        super.init(id: id, TestApp.shared, lastFloatingSize: frame?.size, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @discardableResult
    @MainActor
    static func new(id: UInt32, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, index: Int = INDEX_BIND_LAST, frame: Rect? = nil) -> TestWindow {
        let window = TestWindow(id, parent, adaptiveWeight, index, frame)
        TestApp.shared.windows.append(window)
        return window
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    override func closeAxWindow() {
        unbindFromParent()
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { frame }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { frame?.size }

    override func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        setAxFrameCallCount += 1
        let current = frame ?? Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        frame = Rect(
            topLeftX: topLeft?.x ?? current.topLeftX,
            topLeftY: topLeft?.y ?? current.topLeftY,
            width: size?.width ?? current.width,
            height: size?.height ?? current.height,
        )
    }
}
