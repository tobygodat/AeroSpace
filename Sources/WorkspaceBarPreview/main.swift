// Dev-only harness: renders the menu bar workspace bar with demo data, without starting the window manager.
//
//   swift run WorkspaceBarPreview --snapshot out.png [--appearance dark|light]
//   swift run WorkspaceBarPreview --live 30
//
// --snapshot  renders a sheet of bar states, each on a menu-bar-like strip at 2x, and exits
// --live N    puts the real status item with demo data in the menu bar for N seconds, then exits. Click a group to focus it
@testable import AppBundle
import AppKit
import SwiftUI

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

// Slack is left out on purpose: it draws the missing-icon fallback
let appPaths = [
    "Google Chrome": "/Applications/Google Chrome.app",
    "Capy": "/Applications/Capy.app",
    "Safari": "/Applications/Safari.app",
    "Notion": "/Applications/Notion.app",
    "Discord": "/Applications/Discord.app",
    "Claude": "/Applications/Claude.app",
    "ChatGPT": "/Applications/ChatGPT.app",
    "Finder": "/System/Library/CoreServices/Finder.app",
    "Terminal": "/System/Applications/Utilities/Terminal.app",
]

@MainActor func demoIcon(_ app: WorkspaceBarApp) -> NSImage? {
    guard let path = appPaths[app.name], FileManager.default.fileExists(atPath: path) else { return nil }
    // Safari in /Applications is a symlink, whose icon carries an alias badge
    return NSWorkspace.shared.icon(forFile: URL(filePath: path).resolvingSymlinksInPath().path)
}

func workspace(_ name: String, focused: Bool = false, visible: Bool = false, _ apps: String...) -> WorkspaceBarWorkspace {
    WorkspaceBarWorkspace(
        name: name,
        isFocused: focused,
        isVisible: focused || visible,
        windowApps: apps.map { WorkspaceBarApp(id: $0, name: $0, pid: 0) },
    )
}

func items(_ workspaces: WorkspaceBarWorkspace...) -> [WorkspaceBarItem] {
    workspaceBarItems(workspaces, persistent: ["1", "2", "3", "4", "5"])
}

let mixed = items(
    workspace("1", focused: true, "Google Chrome", "Capy", "Google Chrome"),
    workspace("2"),
    workspace("3", "Slack"),
    workspace("4"),
    workspace("5"),
)

func liveItems(focused: String) -> [WorkspaceBarItem] {
    items(
        workspace("1", focused: focused == "1", "Google Chrome", "Capy"),
        workspace("2", focused: focused == "2"),
        workspace("3", focused: focused == "3", "Slack", "Safari", "Notion", "Discord", "Terminal"),
        workspace("4", focused: focused == "4"),
        workspace("5", focused: focused == "5"),
    )
}

struct Row {
    let title: String
    let items: [WorkspaceBarItem]
    var appIcons = true
    var trayItems: [TrayItem]? = nil
    var maxWidth = CGFloat.infinity
}

let busy = items(
    workspace("1", focused: true, "Google Chrome", "Capy", "Safari"),
    workspace("2", "Notion", "Discord"),
    workspace("3", "Claude", "ChatGPT", "Terminal", "Finder"),
    workspace("4", "Finder"),
    workspace("5"),
)

let rows = [
    Row(title: "(a) Empty: 5 persistent, 1 focused", items: items(
        workspace("1", focused: true), workspace("2"), workspace("3"), workspace("4"), workspace("5"),
    )),
    Row(title: "(b) Mixed: 1 = Chrome + Capy (focused), 3 = Slack (no icon)", items: mixed),
    Row(title: "(c) Many apps: 7 apps on workspace 2", items: items(
        workspace("1", focused: true, "Terminal"),
        workspace("2", "Google Chrome", "Capy", "Safari", "Notion", "Discord", "Claude", "ChatGPT"),
        workspace("3"), workspace("4"), workspace("5"),
    )),
    Row(title: "(d) Two monitors: 1 focused, 3 visible on the other, non-persistent 7", items: items(
        workspace("1", focused: true, "Google Chrome", "Capy"),
        workspace("2"),
        workspace("3", visible: true, "Slack", "Discord"),
        workspace("4"), workspace("5"),
        workspace("7", "Finder"),
        workspace("8"),
    )),
    Row(title: "(e) App icons off", items: mixed, appIcons: false),
    Row(title: "(f) With the AeroSpace menu glyph", items: mixed, trayItems: []),
    Row(title: "(g) With the AeroSpace menu glyph, service mode", items: mixed, trayItems: [
        TrayItem(type: .mode, name: "S", isActive: true, hasFullscreenWindows: false),
    ]),
    Row(title: "(h) Busy workspaces, room to spare", items: busy),
    Row(title: "(i) Same, menu bar room for 260pt: one icon per workspace", items: busy, maxWidth: 260),
    Row(title: "(j) Same, room for 160pt: names only", items: busy, maxWidth: 160),
]

final class SheetView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

final class MenuBarStrip: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(white: isDark ? 0.14 : 0.93, alpha: 1).setFill()
        bounds.fill()
    }
}

@MainActor func menuBarGlyph(_ trayItems: [TrayItem], dark: Bool) -> NSImage? {
    TrayMenuModel.shared.isWorkspaceBarShown = true
    TrayMenuModel.shared.trayItems = trayItems
    let renderer = ImageRenderer(content: MenuBarLabel()
        .environmentObject(TrayMenuModel.shared)
        .environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = 2
    return renderer.cgImage.map { NSImage(cgImage: $0, size: CGSize(width: $0.width / 2, height: $0.height / 2)) }
}

@MainActor func snapshot(to path: String, dark: Bool) throws {
    let width: CGFloat = 520
    let stripHeight: CGFloat = 24
    let sheet = SheetView()
    sheet.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    var y: CGFloat = 12
    for row in rows {
        let label = NSTextField(labelWithString: row.title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = CGRect(x: 12, y: y, width: width - 24, height: 16)
        sheet.addSubview(label)
        y += 20

        let strip = MenuBarStrip(frame: CGRect(x: 0, y: y, width: width, height: stripHeight))
        sheet.addSubview(strip)
        var right = width - 12
        if let trayItems = row.trayItems, let glyph = menuBarGlyph(trayItems, dark: dark) {
            let glyphView = NSImageView(image: glyph)
            glyphView.frame = CGRect(x: right - glyph.size.width, y: (stripHeight - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
            strip.addSubview(glyphView)
            right = glyphView.frame.minX - 8
        }
        let bar = WorkspaceBarView(icon: demoIcon, onSelect: { _ in })
        bar.show(row.items, appIcons: row.appIcons, maxWidth: row.maxWidth)
        let barHeight = NSStatusBar.system.thickness
        bar.frame = CGRect(x: right - bar.barLayout.size.width, y: (stripHeight - barHeight) / 2, width: bar.barLayout.size.width, height: barHeight)
        strip.addSubview(bar)
        y += stripHeight + 14
    }
    sheet.frame = CGRect(x: 0, y: 0, width: width, height: y)

    let scale: CGFloat = 2
    guard let rep = unsafe NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(sheet.bounds.width * scale), pixelsHigh: Int(sheet.bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
    ) else { return }
    rep.size = sheet.bounds.size
    sheet.cacheDisplay(in: sheet.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
    print("snapshot: \(path)")
}

MainActor.assumeIsolated {
    if let path = argValue("--snapshot") {
        do {
            try snapshot(to: path, dark: argValue("--appearance") != "light")
        } catch {
            print("error: \(error)")
            exit(1)
        }
        exit(0)
    }
    guard let seconds = argValue("--live").flatMap(Double.init) else {
        print("usage: WorkspaceBarPreview --snapshot <png> [--appearance dark|light] | --live <seconds>")
        exit(2)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    var bar: WorkspaceBarStatusItem? = nil
    bar = WorkspaceBarStatusItem(icon: demoIcon) { name in
        print("clicked: \(name)")
        bar?.show(liveItems(focused: name), appIcons: true)
    }
    bar?.show(liveItems(focused: "1"), appIcons: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
}
NSApplication.shared.run()
