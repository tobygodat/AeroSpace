@testable import AppBundle
import Common

final class TestApp: AbstractApp {
    let pid: Int32
    let rawAppBundleId: String?
    let name: String?
    let execPath: String? = nil
    let bundlePath: String? = nil
    @MainActor
    static let shared = TestApp()

    private init() {
        self.pid = 0
        self.rawAppBundleId = "bobko.AeroSpace.test-app"
        self.name = rawAppBundleId
    }

    var windows: [Window] = []
    var focusedWindow: Window? = nil
    @MainActor func getFocusedWindow(_ cm: CancellationMode) -> Window? { focusedWindow }
}
