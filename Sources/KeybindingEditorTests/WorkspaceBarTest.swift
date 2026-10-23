@testable import AppBundle
import AppKit
import Testing

private let chrome = WorkspaceBarApp(id: "com.google.Chrome", name: "Google Chrome", pid: 10)
private let capy = WorkspaceBarApp(id: "ai.capy.desktop", name: "Capy", pid: 11)
private let slack = WorkspaceBarApp(id: "com.tinyspeck.slackmacgap", name: "Slack", pid: 12)

private func workspace(_ name: String, focused: Bool = false, visible: Bool = false, _ apps: WorkspaceBarApp...) -> WorkspaceBarWorkspace {
    WorkspaceBarWorkspace(name: name, isFocused: focused, isVisible: focused || visible, windowApps: apps)
}

private func apps(_ count: Int) -> [WorkspaceBarApp] {
    (0 ..< count).map { WorkspaceBarApp(id: "app\($0)", name: "App \($0)", pid: Int32($0)) }
}

private func barLayout(_ items: [WorkspaceBarItem], appIcons: Bool = true, maxWidth: CGFloat = .infinity) -> WorkspaceBarLayout {
    layoutWorkspaceBar(items, appIcons: appIcons, height: 22, maxWidth: maxWidth) { text, _ in CGFloat(text.count) * 7 }
}

private let fiveItems = (1 ... 5).map { WorkspaceBarItem(name: String($0), state: $0 == 1 ? .focused : .hidden, apps: $0 == 3 ? [slack] : []) }

struct WorkspaceBarTest {
    @Test func groupsOneIconPerAppInFirstWindowOrder() {
        let items = workspaceBarItems([workspace("1", focused: true, capy, chrome, capy, slack, chrome)], persistent: ["1"])
        #expect(items == [WorkspaceBarItem(name: "1", state: .focused, apps: [capy, chrome, slack])])
    }

    @Test func showsPersistentWorkspacesEvenWhenEmpty() {
        let items = workspaceBarItems([workspace("1", focused: true), workspace("2"), workspace("3")], persistent: ["1", "2", "3"])
        #expect(items.map(\.name) == ["1", "2", "3"])
    }

    @Test func showsPersistentWorkspacesThatDontExistYetInNameOrder() {
        let items = workspaceBarItems([workspace("2", focused: true), workspace("10", chrome), workspace("S", slack)], persistent: ["1", "2", "3"])
        #expect(items.map(\.name) == ["1", "2", "3", "10", "S"])
        #expect(items.map(\.state) == [.hidden, .focused, .hidden, .hidden, .hidden])
    }

    @Test func hidesOtherEmptyWorkspacesUnlessOnAMonitor() {
        let items = workspaceBarItems([
            workspace("1"),
            workspace("6"),
            workspace("7", chrome),
            workspace("8", visible: true),
            workspace("9", focused: true),
        ], persistent: ["1"])
        #expect(items.map(\.name) == ["1", "7", "8", "9"])
    }

    @Test func statesFollowFocusThenVisibility() {
        let items = workspaceBarItems([
            workspace("1", focused: true),
            workspace("2", visible: true, slack),
            workspace("3", chrome),
        ], persistent: [])
        #expect(items.map(\.state) == [.focused, .visible, .hidden])
    }

    @Test func centerOfEachGroupHitsItself() {
        let layout = barLayout(fiveItems)
        for group in layout.groups {
            #expect(hitWorkspace(layout, x: group.frame.midX)?.name == group.item.name)
            #expect(hitWorkspace(layout, x: group.nameFrame.midX)?.name == group.item.name)
        }
    }

    @Test func gapsResolveToTheNearestGroup() {
        let layout = barLayout(fiveItems)
        for (left, right) in zip(layout.groups, layout.groups.dropFirst()) {
            let gap = right.frame.minX - left.frame.maxX
            #expect(gap > 0)
            #expect(hitWorkspace(layout, x: left.frame.maxX + gap / 4)?.name == left.item.name)
            #expect(hitWorkspace(layout, x: right.frame.minX - gap / 4)?.name == right.item.name)
        }
    }

    @Test func pointsPastTheEndsClampToTheFirstAndLastGroup() {
        let layout = barLayout(fiveItems)
        #expect(hitWorkspace(layout, x: -100)?.name == "1")
        #expect(hitWorkspace(layout, x: 0)?.name == "1")
        #expect(hitWorkspace(layout, x: layout.size.width)?.name == "5")
        #expect(hitWorkspace(layout, x: layout.size.width + 100)?.name == "5")
        #expect(hitWorkspace(barLayout([]), x: 10) == nil)
    }

    @Test func moreThanThreeAppsShowThreeIconsAndACount() throws {
        let group = try #require(barLayout([WorkspaceBarItem(name: "1", state: .hidden, apps: apps(7))]).groups.first)
        #expect(group.iconFrames.count == 3)
        let overflow = try #require(group.overflow)
        #expect(overflow.text == "+4")
        #expect(overflow.frame.minX >= group.iconFrames[2].maxX)
        #expect(group.frame.contains(overflow.frame))
    }

    @Test func iconsOffShowsNamesOnly() throws {
        let group = try #require(barLayout([WorkspaceBarItem(name: "1", state: .focused, apps: apps(7))], appIcons: false).groups.first)
        #expect(group.iconFrames.isEmpty)
        #expect(group.overflow == nil)
        #expect(group.frame.width == barLayout([WorkspaceBarItem(name: "1", state: .focused, apps: [])]).groups[0].frame.width)
    }

    @Test func widthGrowsWithAppsUntilTheIconCap() {
        let widths = (0 ... 6).map { count in
            barLayout([WorkspaceBarItem(name: "1", state: .hidden, apps: apps(count))]).size.width
        }
        #expect(widths[0] < widths[1] && widths[1] < widths[2] && widths[2] < widths[3])
        #expect(widths[3] < widths[4])
        #expect(widths[4] == widths[5] && widths[5] == widths[6])
        for count in 0 ... 6 {
            #expect(barLayout([WorkspaceBarItem(name: "1", state: .hidden, apps: apps(count))]).groups[0].iconFrames.count == min(count, 3))
        }
    }

    @Test func tooWideDropsToOneIconThenNamesOnly() {
        let busy = (1 ... 9).map { WorkspaceBarItem(name: String($0), state: .hidden, apps: apps($0 % 4 + 1)) }
        let full = barLayout(busy)
        let oneIcon = barLayout(busy, maxWidth: full.size.width - 1)
        let namesOnly = barLayout(busy, maxWidth: oneIcon.size.width - 1)
        #expect(oneIcon.size.width < full.size.width)
        #expect(oneIcon.groups.allSatisfy { $0.iconFrames.count == 1 })
        #expect(oneIcon.groups.map { $0.overflow?.text } == busy.map { $0.apps.count > 1 ? "+\($0.apps.count - 1)" : nil })
        #expect(namesOnly == barLayout(busy, appIcons: false))
        #expect(barLayout(busy, maxWidth: 1).groups.map(\.item) == busy)
        #expect(barLayout(busy, maxWidth: full.size.width) == full)
    }

    @Test func groupsDoNotOverlapAndFitTheBar() {
        let layout = barLayout(fiveItems)
        for (left, right) in zip(layout.groups, layout.groups.dropFirst()) {
            #expect(left.frame.maxX < right.frame.minX)
        }
        for group in layout.groups {
            #expect(group.frame.minX >= 0 && group.frame.maxX <= layout.size.width)
            #expect(group.frame.minY >= 0 && group.frame.maxY <= layout.size.height)
        }
    }
}
