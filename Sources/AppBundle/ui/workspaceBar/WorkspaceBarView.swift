import AppKit
import Common
import SwiftUI

final class WorkspaceBarView: NSView, NSViewToolTipOwner {
    private var items: [WorkspaceBarItem] = []
    private var appIcons = true
    private var maxWidth = CGFloat.infinity
    private(set) var barLayout = WorkspaceBarLayout(size: .zero, groups: [])
    private let icon: (WorkspaceBarApp) -> NSImage?
    private let onSelect: (String) -> Void

    init(icon: @escaping (WorkspaceBarApp) -> NSImage?, onSelect: @escaping (String) -> Void) {
        self.icon = icon
        self.onSelect = onSelect
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { die("Not implemented") }

    func show(_ items: [WorkspaceBarItem], appIcons: Bool, maxWidth: CGFloat = .infinity) {
        if items == self.items && appIcons == self.appIcons && maxWidth == self.maxWidth { return }
        self.items = items
        self.appIcons = appIcons
        self.maxWidth = maxWidth
        relayout()
        setAccessibilityLabel("Workspaces: " + items.map(accessibilityDescription).joined(separator: "; "))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        barLayout = layoutWorkspaceBar(items, appIcons: appIcons, height: bounds.height, maxWidth: maxWidth) { text, font in
            NSAttributedString(string: text, attributes: [.font: font]).size().width
        }
        removeAllToolTips()
        for group in barLayout.groups {
            unsafe addToolTip(group.frame, owner: self, userData: nil)
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let item = hitWorkspace(barLayout, x: x), item.state != .focused else { return }
        onSelect(item.name)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let item = hitWorkspace(barLayout, x: point.x) else { return "" }
        return item.name + " · " + (item.apps.isEmpty ? "Empty" : item.apps.map(\.name).joined(separator: ", "))
    }

    override func draw(_ dirtyRect: NSRect) {
        let m = WorkspaceBarMetrics.self
        for group in barLayout.groups {
            switch group.item.state {
                case .focused:
                    NSColor.labelColor.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: group.frame, xRadius: m.cornerRadius, yRadius: m.cornerRadius).fill()
                case .visible:
                    let outline = NSBezierPath(roundedRect: group.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: m.cornerRadius - 0.5, yRadius: m.cornerRadius - 0.5)
                    outline.lineWidth = 1
                    NSColor.labelColor.withAlphaComponent(0.35).setStroke()
                    outline.stroke()
                case .hidden:
                    break
            }
            let isEmpty = group.item.state == .hidden && group.item.apps.isEmpty
            drawText(group.item.name, in: group.nameFrame, font: m.nameFont, color: isEmpty ? .tertiaryLabelColor : .labelColor)
            for (app, frame) in zip(group.item.apps, group.iconFrames) {
                if let image = icon(app) {
                    image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    drawPlaceholderIcon(app, in: frame)
                }
            }
            if let overflow = group.overflow {
                drawText(overflow.text, in: overflow.frame, font: m.overflowFont, color: .secondaryLabelColor)
            }
        }
    }

    private func drawPlaceholderIcon(_ app: WorkspaceBarApp, in frame: CGRect) {
        let square = frame.insetBy(dx: 1, dy: 1)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: square, xRadius: 3.5, yRadius: 3.5).fill()
        drawText(app.name.first.map { String($0).uppercased() } ?? "", in: square, font: .systemFont(ofSize: 9, weight: .bold), color: .labelColor)
    }

    private func drawText(_ text: String, in frame: CGRect, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let width = string.size().width
        // Center the cap height rather than the line box so digits sit optically in the middle
        let baseline = (frame.midY - font.capHeight / 2).rounded(.toNearestOrEven)
        string.draw(at: CGPoint(x: frame.midX - width / 2, y: baseline + font.descender))
    }
}

/// The bar exactly as the menu bar draws it, for the Settings window
struct InlineWorkspaceBar: NSViewRepresentable {
    let items: [WorkspaceBarItem]
    let appIcons: Bool
    let maxWidth: CGFloat

    func makeNSView(context: Context) -> WorkspaceBarView {
        WorkspaceBarView(icon: workspaceBarAppIcon, onSelect: { _ in })
    }

    func updateNSView(_ view: WorkspaceBarView, context: Context) {
        view.show(items, appIcons: appIcons, maxWidth: maxWidth)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: WorkspaceBarView, context: Context) -> CGSize? {
        let width = view.barLayout.size.width
        return CGSize(width: min(width, proposal.width ?? width), height: NSStatusBar.system.thickness)
    }
}

private func accessibilityDescription(_ item: WorkspaceBarItem) -> String {
    let state: [String] = switch item.state {
        case .focused: ["focused"]
        case .visible: ["visible on another display"]
        case .hidden: []
    }
    let apps = item.apps.isEmpty ? ["empty"] : item.apps.map(\.name)
    return ([item.name] + state + apps).joined(separator: ", ")
}
