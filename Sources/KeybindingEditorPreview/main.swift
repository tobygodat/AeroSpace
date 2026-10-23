// Dev-only harness: shows the keybinding editor for a scratch copy of a config, without starting the window manager.
//
//   swift run KeybindingEditorPreview --config /path/to/copy.toml [--snapshot out.png] [--demo]
//
// --snapshot  renders the window to a PNG and exits
// --demo      before the snapshot: records ⌥⇧G into the first binding, changes one command, and saves
// --appearance light|dark
// --select N  expands the Nth binding of the main mode
// --pane NAME  opens a Settings pane instead of the bindings (e.g. workspaces)
// --edit N=command  with --demo: which binding's command to change (default 1=fullscreen)
// --dump      prints the first bindings of the main mode
// --redraw    forces a full layout and redraw before the snapshot
// --super-status on|failed  shows that Super key state (no event tap or key remap is started)
@testable import AppBundle
import AppKit
import SwiftUI

let args = CommandLine.arguments
func argValue(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

guard let configPath = argValue("--config") else {
    print("usage: KeybindingEditorPreview --config <file> [--snapshot <png>] [--demo]")
    exit(2)
}
let snapshotPath = argValue("--snapshot")
let demo = args.contains("--demo")
let appearance = argValue("--appearance")
let selectIndex = argValue("--select").flatMap(Int.init)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let model = KeybindingEditorModel(configUrlProvider: { .success(URL(filePath: configPath)) }, afterSave: { print("afterSave called") })
    model.load()
    switch argValue("--super-status") {
        case "on": SuperKeyRuntime.shared.status = .on(model.superKey)
        case "failed": SuperKeyRuntime.shared.status = .failed("AeroSpace lost Accessibility permission")
        default: break
    }

    // A utility panel so tiling window managers leave it floating
    let window = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
        styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
        backing: .buffered,
        defer: false,
    )
    window.title = "Settings"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    switch appearance {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: break
    }
    window.contentView = NSHostingView(rootView: KeybindingEditorView(model: model, pane: argValue("--pane").flatMap(SettingsPane.init(rawValue:))))
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    if demo || snapshotPath != nil {
        Task { @MainActor in
            try await Task.sleep(for: .milliseconds(800))
            if demo, let first = model.modes.first?.bindings.first {
                model.startRecording(first.id)
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "G", charactersIgnoringModifiers: "g",
                    isARepeat: false, keyCode: 5,
                )
                if let event { app.postEvent(event, atStart: false) } // Goes through the real local event monitor
                try await Task.sleep(for: .milliseconds(300))
                print("recorded: \(model.modes[0].bindings[0].key)")
                let edit = argValue("--edit").map { $0.split(separator: "=", maxSplits: 1).map(String.init) } ?? ["1", "fullscreen"]
                if let index = Int(edit[0]), model.modes[0].bindings.indices.contains(index) {
                    model.modes[0].bindings[index].commands = [edit[1]]
                }
                await model.save()
                print("status: \(model.status?.text ?? "-")")
                // Show what a mistake looks like in the snapshot
                model.modes[0].bindings.append(EditableBinding(originalKey: nil, key: "alt-shift-g", commands: ["not-a-command"]))
                try await Task.sleep(for: .milliseconds(300))
            }
            if let selectIndex, let binding = model.modes.first?.bindings.dropFirst(selectIndex).first {
                model.selectedBindingId = binding.id
                try await Task.sleep(for: .milliseconds(300))
            }
            if args.contains("--dump") {
                for binding in model.modes.first?.bindings.prefix(4) ?? [] {
                    print("dump: \(binding.key) -> \(binding.commands) [\(describeCommands(binding.normalizedCommands).category)]")
                }
            }
            if args.contains("--redraw"), let root = window.contentView {
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
                root.setNeedsDisplay(root.bounds)
                root.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
            }
            if let snapshotPath, let view = window.contentView?.superview, let layer = view.layer {
                // Render the layer tree: cacheDisplay(in:to:) skips most SwiftUI controls
                let scale = window.backingScaleFactor
                let size = view.bounds.size
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0,
                )
                if let rep, let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
                    context.scaleBy(x: scale, y: scale)
                    layer.render(in: context)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: snapshotPath))
                    print("snapshot: \(snapshotPath)")
                }
                exit(0)
            }
        }
    }
}
NSApplication.shared.run()
