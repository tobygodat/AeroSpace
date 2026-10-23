import Common
import SwiftUI
import UniformTypeIdentifiers

public let keybindingEditorWindowId = "\(aeroSpaceAppName).keybindingEditor"

@MainActor
public func getKeybindingEditorWindow() -> some Scene {
    // Using SwiftUI.Window because another class in AeroSpace is already called Window
    SwiftUI.Window("Keybindings", id: keybindingEditorWindowId) {
        KeybindingEditorView(model: KeybindingEditorModel.shared)
            .onAppear {
                // Set activation policy; otherwise, AeroSpace windows won't be able to receive focus and accept keyboard input
                NSApp.setActivationPolicy(.accessory)
            }
    }
    .defaultSize(width: 820, height: 640)
    .windowResizability(.contentMinSize)
}

struct OpenKeybindingEditorButton: View {
    @Environment(\.openWindow) private var openWindow: OpenWindowAction

    var body: some View {
        Button("Keybindings…") {
            openWindow(id: keybindingEditorWindowId)
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("K", modifiers: .command)
    }
}

struct KeybindingEditorView: View {
    @ObservedObject var model: KeybindingEditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let loadError = model.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundColor(.yellow)
                    Text(loadError).multilineTextAlignment(.center).textSelection(.enabled)
                    HStack {
                        Button("Reload") { model.load() }
                        openConfigButton()
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                bindingList
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { model.loadIfClean() }
        .onDisappear { model.stopRecording() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if model.modes.count > 1 {
                Picker("Mode", selection: $model.selectedMode) {
                    ForEach(model.modes, id: \.name) { mode in
                        Text(mode.name).tag(mode.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            TextField("Search shortcuts or commands", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
            Menu("Presets") {
                ForEach(keybindingPresets()) { preset in
                    Button(preset.name) { model.apply(preset) }
                }
            }
            .fixedSize()
            Button {
                model.addBinding()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(12)
    }

    private var bindingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Click a shortcut, then press the new keys. Esc cancels.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                if let modeIndex = model.selectedModeIndex {
                    let mode = model.modes[modeIndex]
                    ForEach($model.modes[modeIndex].bindings) { $binding in
                        if model.matchesSearch(binding) {
                            KeybindingRow(
                                binding: $binding,
                                isRecording: model.recordingBindingId == binding.id,
                                errors: model.errors(for: binding, in: mode),
                                warning: model.warning(for: binding),
                                onRecord: { model.toggleRecording(binding.id) },
                                onDelete: { model.deleteBinding(binding.id) },
                            )
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let status = model.status {
                    Text(status.text)
                        .foregroundColor(status.isError ? .red : .secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else if let url = model.configFileUrl {
                    Text(url.displayPath).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.callout)
            Spacer()
            Button("Reload") { model.load() }
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty)
            Button("Save") {
                Task.startUnstructured { await model.save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.isDirty || model.hasErrors)
        }
        .padding(12)
    }
}

struct KeybindingRow: View {
    @Binding var binding: EditableBinding
    let isRecording: Bool
    let errors: [String]
    let warning: String?
    let onRecord: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: onRecord) {
                        Text(isRecording ? "Press keys…" : binding.key.isEmpty ? "Record" : prettyShortcut(binding.key))
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .frame(width: 130)
                    }
                    .buttonStyle(.bordered)
                    .tint(isRecording ? .accentColor : nil)
                    .controlSize(.large)
                    .help("Click, then press the shortcut you want")
                    TextField("key", text: $binding.key)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10).monospaced())
                        .foregroundColor(.secondary)
                        .frame(width: 140)
                        .help("Shortcut in config notation, e.g. alt-shift-1")
                }
                TextField("Command, e.g. workspace 1", text: commandsText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body).monospaced())
                    .lineLimit(1 ... 4)
                KeybindingActionMenu(binding: $binding)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete binding")
                .padding(.top, 4)
            }
            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .font(.callout)
            }
            if let warning, errors.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isRecording ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    /// One command per line
    private var commandsText: Binding<String> {
        Binding(
            get: { binding.commands.joined(separator: "\n") },
            set: { binding.commands = $0.components(separatedBy: "\n") },
        )
    }
}

struct KeybindingActionMenu: View {
    @Binding var binding: EditableBinding

    var body: some View {
        Menu {
            Button("Open app…") { pickApp() }
            Menu("Workspace") {
                ForEach(1 ... 9, id: \.self) { n in
                    Button("Switch to workspace \(n)") { set("workspace \(n)") }
                }
                Divider()
                ForEach(1 ... 9, id: \.self) { n in
                    Button("Move window to workspace \(n)") { set("move-node-to-workspace --focus-follows-window \(n)") }
                }
                Divider()
                Button("Next workspace") { set("workspace --wrap-around next") }
                Button("Previous workspace") { set("workspace --wrap-around prev") }
                Button("Last used workspace") { set("workspace-back-and-forth") }
            }
            Menu("Window") {
                Button("Close") { set("close") }
                Button("Fullscreen") { set("fullscreen") }
                Button("Toggle floating / tiling") { set("layout floating tiling") }
                Button("Toggle split direction") { set("layout horizontal vertical") }
                Button("Toggle tiles / accordion") { set("layout tiles accordion") }
                Button("Minimize") { set("macos-native-minimize") }
                Divider()
                ForEach(["left", "right", "up", "down"], id: \.self) { direction in
                    Button("Focus \(direction)") { set("focus \(direction)") }
                }
                Divider()
                ForEach(["left", "right", "up", "down"], id: \.self) { direction in
                    Button("Move \(direction)") { set("move \(direction)") }
                }
                Divider()
                Button("Grow") { set("resize smart +50") }
                Button("Shrink") { set("resize smart -50") }
            }
            Menu("AeroSpace") {
                Button("Reload config") { set("reload-config") }
                Button("Enter service mode") { set("mode service") }
                Button("Back to main mode") { set("mode main") }
                Button("Enable / disable tiling") { set("enable toggle") }
            }
        } label: {
            Image(systemName: "bolt.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pick an action")
        .padding(.top, 4)
    }

    private func set(_ command: String) {
        binding.commands = [command]
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            set(openAppCommand(name: url.deletingPathExtension().lastPathComponent))
        }
    }
}
