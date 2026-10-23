import AppKit
import Common
import OrderedCollections

struct WorkspaceBarApp: Equatable {
    let id: String
    let name: String
    let pid: Int32
}

enum WorkspaceBarItemState: Equatable {
    case focused
    case visible
    case hidden
}

struct WorkspaceBarItem: Equatable {
    let name: String
    let state: WorkspaceBarItemState
    /// One per app, in the order its first window appears in the workspace tree
    let apps: [WorkspaceBarApp]
}

struct WorkspaceBarWorkspace {
    let name: String
    let isFocused: Bool
    let isVisible: Bool
    let windowApps: [WorkspaceBarApp]
}

/// Persistent workspaces show even before they exist (right after the count goes up), sorted in by name
func workspaceBarItems(_ workspaces: [WorkspaceBarWorkspace], persistent: OrderedSet<String>) -> [WorkspaceBarItem] {
    let existing = Set(workspaces.map(\.name))
    let missing = persistent.filter { !existing.contains($0) }
        .map { WorkspaceBarWorkspace(name: $0, isFocused: false, isVisible: false, windowApps: []) }
    let all = missing.isEmpty ? workspaces : (workspaces + missing).sorted { $0.name.toLogicalSegments() < $1.name.toLogicalSegments() }
    return all.compactMap { workspace in
        let isShown = persistent.contains(workspace.name) || !workspace.windowApps.isEmpty || workspace.isVisible || workspace.isFocused
        guard isShown else { return nil }
        let state: WorkspaceBarItemState = switch true {
            case workspace.isFocused: .focused
            case workspace.isVisible: .visible
            default: .hidden
        }
        var seenAppIds: Set<String> = []
        return WorkspaceBarItem(name: workspace.name, state: state, apps: workspace.windowApps.filter { seenAppIds.insert($0.id).inserted })
    }
}

enum WorkspaceBarMetrics {
    static let pillHeight: CGFloat = 20
    static let cornerRadius: CGFloat = 6
    static let padding: CGFloat = 6
    static let nameToIcons: CGFloat = 4
    static let iconSize: CGFloat = 16
    static let iconSpacing: CGFloat = 2
    static let iconsToOverflow: CGFloat = 2
    static let maxIcons = 3
    static let groupSpacing: CGFloat = 2
    static let edgeInset: CGFloat = 2
    static var nameFont: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .medium) }
    static var overflowFont: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
}

struct WorkspaceBarLayout: Equatable {
    struct Overflow: Equatable {
        let text: String
        let frame: CGRect
    }

    struct Group: Equatable {
        let item: WorkspaceBarItem
        let frame: CGRect
        let nameFrame: CGRect
        let iconFrames: [CGRect]
        let overflow: Overflow?
    }

    let size: CGSize
    let groups: [Group]
}

/// macOS hides a status item that doesn't fit instead of truncating it, so past `maxWidth` the bar shows one icon per
/// workspace, then names only
func layoutWorkspaceBar(
    _ items: [WorkspaceBarItem],
    appIcons: Bool,
    height: CGFloat,
    maxWidth: CGFloat = .infinity,
    measure: (String, NSFont) -> CGFloat,
) -> WorkspaceBarLayout {
    let iconCaps = appIcons ? [WorkspaceBarMetrics.maxIcons, 1] : []
    for iconCap in iconCaps {
        let layout = layoutWorkspaceBar(items, iconCap: iconCap, height: height, measure: measure)
        if layout.size.width <= maxWidth { return layout }
    }
    return layoutWorkspaceBar(items, iconCap: 0, height: height, measure: measure)
}

private func layoutWorkspaceBar(
    _ items: [WorkspaceBarItem],
    iconCap: Int,
    height: CGFloat,
    measure: (String, NSFont) -> CGFloat,
) -> WorkspaceBarLayout {
    let m = WorkspaceBarMetrics.self
    let pillY = (height - m.pillHeight) / 2
    var x = m.edgeInset
    var groups: [WorkspaceBarLayout.Group] = []
    for item in items {
        let nameFrame = CGRect(x: x + m.padding, y: pillY, width: ceil(measure(item.name, m.nameFont)), height: m.pillHeight)
        var contentMaxX = nameFrame.maxX
        var iconFrames: [CGRect] = []
        var overflow: WorkspaceBarLayout.Overflow? = nil
        if iconCap > 0 && !item.apps.isEmpty {
            for index in item.apps.prefix(iconCap).indices {
                let iconX = contentMaxX + (index == 0 ? m.nameToIcons : m.iconSpacing)
                iconFrames.append(CGRect(x: iconX, y: (height - m.iconSize) / 2, width: m.iconSize, height: m.iconSize))
                contentMaxX = iconX + m.iconSize
            }
            if item.apps.count > iconCap {
                let text = "+\(item.apps.count - iconCap)"
                let frame = CGRect(x: contentMaxX + m.iconsToOverflow, y: pillY, width: ceil(measure(text, m.overflowFont)), height: m.pillHeight)
                overflow = WorkspaceBarLayout.Overflow(text: text, frame: frame)
                contentMaxX = frame.maxX
            }
        }
        let frame = CGRect(x: x, y: pillY, width: contentMaxX + m.padding - x, height: m.pillHeight)
        groups.append(WorkspaceBarLayout.Group(item: item, frame: frame, nameFrame: nameFrame, iconFrames: iconFrames, overflow: overflow))
        x = frame.maxX + m.groupSpacing
    }
    return WorkspaceBarLayout(size: CGSize(width: (groups.last?.frame.maxX ?? 0) + m.edgeInset, height: height), groups: groups)
}

/// The group under `x`. Gaps resolve to the nearest group, so the whole bar is clickable
func hitWorkspace(_ layout: WorkspaceBarLayout, x: CGFloat) -> WorkspaceBarItem? {
    layout.groups.min { distance($0.frame, x) < distance($1.frame, x) }?.item
}

private func distance(_ frame: CGRect, _ x: CGFloat) -> CGFloat {
    max(frame.minX - x, 0, x - frame.maxX)
}
