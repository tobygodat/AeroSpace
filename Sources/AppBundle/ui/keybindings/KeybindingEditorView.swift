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
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 920, height: 640)
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

// MARK: - Theme

enum KBTheme {
    static let background = dynamic(light: 0xFCFCFD, dark: 0x111113)
    static let sidebar = dynamic(light: 0xF5F5F7, dark: 0x0C0C0D)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x1A1A1D)
    static let hover = dynamic(light: 0x000000, 0.035, dark: 0xFFFFFF, 0.035)
    static let selected = dynamic(light: 0x000000, 0.06, dark: 0xFFFFFF, 0.06)
    static let border = dynamic(light: 0x000000, 0.08, dark: 0xFFFFFF, 0.075)
    static let textPrimary = dynamic(light: 0x1C1C21, dark: 0xEDEDEF)
    static let textSecondary = dynamic(light: 0x5E5E68, dark: 0xA0A0A8)
    static let textTertiary = dynamic(light: 0x8F8F98, dark: 0x6C6C75)
    static let accent = Color(nsColor: rgb(0x5E6AD2))
    static let accentText = dynamic(light: 0x5E6AD2, dark: 0x9BA3F5)
    static let danger = Color(nsColor: rgb(0xE5484D))
    static let caution = Color(nsColor: rgb(0xF0A04B))
    static let success = Color(nsColor: rgb(0x4CB782))

    private static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha,
        )
    }

    private static func dynamic(light: Int, _ lightAlpha: CGFloat = 1, dark: Int, _ darkAlpha: CGFloat = 1) -> Color {
        let lightColor = rgb(light, lightAlpha)
        let darkColor = rgb(dark, darkAlpha)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

// MARK: - Editor

struct KeybindingEditorView: View {
    @ObservedObject var model: KeybindingEditorModel
    @FocusState private var isSearchFocused: Bool
    /// Keeps the selected row in its group while its command is being edited, so it doesn't jump around
    @State private var stickyCategory: (id: UUID, category: KeybindingCategory)? = nil

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Hairline(vertical: true)
            VStack(spacing: 0) {
                header
                Hairline()
                if let loadError = model.loadError {
                    loadErrorView(loadError)
                } else {
                    bindingList
                }
                Hairline()
                bottomBar
            }
            .background(KBTheme.background)
        }
        .ignoresSafeArea(.container, edges: .top) // Run under the hidden title bar
        .frame(minWidth: 780, minHeight: 480)
        .background(shortcutButtons)
        .onAppear { model.loadIfClean() }
        .onDisappear { model.stopRecording() }
        .onChange(of: model.selectedBindingId) { _ in stickyCategory = nil }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(KBTheme.accentText)
                Text("Keybindings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(KBTheme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 48) // Clears the traffic lights
            .padding(.bottom, 16)

            SidebarLabel("Modes")
            ForEach(model.modes, id: \.name) { mode in
                SidebarItem(
                    icon: mode.name == mainModeId ? "keyboard" : "square.stack.3d.up",
                    title: mode.name,
                    trailing: "\(mode.bindings.count)",
                    isSelected: model.selectedMode == mode.name,
                ) {
                    model.selectedMode = mode.name
                    model.selectedBindingId = nil
                }
            }

            SidebarLabel("Presets").padding(.top, 18)
            ForEach(keybindingPresets()) { preset in
                SidebarItem(icon: "sparkles", title: preset.name, trailing: nil, isSelected: false) {
                    model.apply(preset)
                }
                .help("Replace the main mode with this preset. Nothing is saved until you press Save")
            }

            Spacer()

            if let url = model.configFileUrl {
                SidebarLabel("Config file")
                SidebarItem(icon: "doc.text", title: url.displayPath, trailing: nil, isSelected: false) {
                    url.open(with: getTextEditorToOpenConfig())
                }
                .help("Open the config file in a text editor")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(KBTheme.sidebar)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.selectedMode)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KBTheme.textPrimary)
            Text("\(model.modes.first { $0.name == model.selectedMode }?.bindings.count ?? 0) bindings")
                .font(.system(size: 12))
                .foregroundStyle(KBTheme.textTertiary)
            Spacer()
            searchField
                .frame(width: 240)
            Button {
                model.addBinding()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("New binding")
                }
            }
            .buttonStyle(KBAccentButtonStyle())
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(KBTheme.textTertiary)
            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(KBTheme.textPrimary)
                .focused($isSearchFocused)
            if model.searchText.isEmpty {
                KeyHint("⌘F")
            } else {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(KBTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(KBTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSearchFocused ? KBTheme.accent.opacity(0.7) : KBTheme.border))
    }

    // MARK: List

    private struct Group: Identifiable {
        let category: KeybindingCategory
        let bindings: [EditableBinding]
        var id: String { category.rawValue }
    }

    private var groups: [Group] {
        guard let mode = model.modes.first(where: { $0.name == model.selectedMode }) else { return [] }
        var byCategory: [KeybindingCategory: [EditableBinding]] = [:]
        for binding in mode.bindings where model.matchesSearch(binding) {
            let category = stickyCategory?.id == binding.id
                ? stickyCategory!.category
                : describeCommands(binding.normalizedCommands).category
            byCategory[category, default: []].append(binding)
        }
        return KeybindingCategory.allCases.compactMap { category in
            byCategory[category].map { Group(category: category, bindings: $0) }
        }
    }

    private var bindingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                let groups = groups
                if groups.isEmpty {
                    emptyState
                }
                ForEach(groups) { group in
                    Section {
                        // Scope row identity to its group: LazyVStack otherwise keeps showing a stale row
                        // when a binding moves to another group after its command changes
                        ForEach(group.bindings.map { (key: "\(group.id)/\($0.id)", binding: $0) }, id: \.key) { item in
                            row(item.binding)
                        }
                    } header: {
                        SectionHeader(title: group.category.rawValue, count: group.bindings.count)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func row(_ binding: EditableBinding) -> some View {
        let mode = model.modes.first { $0.name == model.selectedMode } ?? EditableMode(name: model.selectedMode, bindings: [])
        let id = binding.id
        return KeybindingRowView(
            binding: binding,
            update: { newValue in
                for modeIndex in model.modes.indices {
                    if let index = model.modes[modeIndex].bindings.firstIndex(where: { $0.id == id }) {
                        model.modes[modeIndex].bindings[index] = newValue
                    }
                }
            },
            isSelected: model.selectedBindingId == id,
            isRecording: model.recordingBindingId == id,
            errors: model.errors(for: binding, in: mode),
            warning: model.warning(for: binding),
            onSelect: {
                if model.selectedBindingId == id {
                    model.selectedBindingId = nil
                } else {
                    model.selectedBindingId = id
                    stickyCategory = (id, describeCommands(binding.normalizedCommands).category)
                }
            },
            onRecord: {
                model.selectedBindingId = id
                stickyCategory = (id, describeCommands(binding.normalizedCommands).category)
                model.toggleRecording(id)
            },
            onDelete: { model.deleteBinding(id) },
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(KBTheme.textTertiary)
            Text(model.searchText.isEmpty ? "No bindings in this mode" : "No bindings match “\(model.searchText)”")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(KBTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func loadErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(KBTheme.caution)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(KBTheme.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Try again") { model.load() }
                .buttonStyle(KBGhostButtonStyle())
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let status = model.status {
                StatusDot(color: status.isError ? KBTheme.danger : KBTheme.success)
                Text(status.text)
                    .foregroundStyle(status.isError ? KBTheme.danger : KBTheme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if model.isDirty {
                StatusDot(color: KBTheme.accent)
                let count = model.unsavedChangeCount
                Text("\(count) unsaved \(count == 1 ? "change" : "changes")")
                    .foregroundStyle(KBTheme.textSecondary)
            } else {
                Text("Click a shortcut to record new keys")
                    .foregroundStyle(KBTheme.textTertiary)
            }
            Spacer()
            Button("Reload") { model.load() }
                .buttonStyle(KBGhostButtonStyle())
                .help("Re-read the config file from disk")
            Button("Revert") { model.revert() }
                .buttonStyle(KBGhostButtonStyle())
                .disabled(!model.isDirty)
            Button {
                Task.startUnstructured { await model.save() }
            } label: {
                HStack(spacing: 6) {
                    Text("Save")
                    Text("⌘S").opacity(0.6)
                }
            }
            .buttonStyle(KBAccentButtonStyle())
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.isDirty || model.hasErrors)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    /// Invisible buttons that only exist for their keyboard shortcuts
    private var shortcutButtons: some View {
        Button("") { isSearchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
    }
}

// MARK: - Row

struct KeybindingRowView: View {
    /// Passed by value (not as a Binding) so SwiftUI re-renders the row whenever the binding changes
    let binding: EditableBinding
    let update: (EditableBinding) -> Void
    let isSelected: Bool
    let isRecording: Bool
    let errors: [String]
    let warning: String?
    let onSelect: () -> Void
    let onRecord: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        let description = describeCommands(binding.normalizedCommands)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ShortcutButton(notation: binding.key, isRecording: isRecording, action: onRecord)
                    .frame(width: 140, alignment: .leading)
                Text(description.title)
                    .font(.system(size: 13))
                    .foregroundStyle(KBTheme.textPrimary)
                    .lineLimit(1)
                if !errors.isEmpty {
                    StatusDot(color: KBTheme.danger)
                } else if warning != nil {
                    StatusDot(color: KBTheme.caution)
                }
                Spacer(minLength: 16)
                if !isSelected {
                    Text(binding.normalizedCommands.joined(separator: " ; "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(KBTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 300, alignment: .trailing)
                }
            }
            .frame(height: 38)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            if isSelected {
                editor
                    .padding(.leading, 154)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? KBTheme.selected : isHovered ? KBTheme.hover : Color.clear),
        )
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                TextField("Command, e.g. workspace 1", text: commandsText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(KBTheme.textPrimary)
                    .lineLimit(1 ... 5)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(KBTheme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KBTheme.border))
                KeybindingActionMenu(binding: editable)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(KBGhostButtonStyle(tint: KBTheme.danger))
                .help("Delete binding")
            }
            HStack(spacing: 8) {
                Text("Shortcut")
                    .font(.system(size: 11))
                    .foregroundStyle(KBTheme.textTertiary)
                TextField("e.g. alt-shift-1", text: editable.key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(KBTheme.textSecondary)
                    .frame(width: 200)
                    .help("Shortcut in config notation")
            }
            ForEach(errors, id: \.self) { error in
                Message(text: error, color: KBTheme.danger)
            }
            if let warning, errors.isEmpty {
                Message(text: warning, color: KBTheme.caution)
            }
        }
    }

    private var editable: Binding<EditableBinding> {
        Binding(get: { binding }, set: update)
    }

    /// One command per line
    private var commandsText: Binding<String> {
        Binding(
            get: { binding.commands.joined(separator: "\n") },
            set: { newValue in
                var copy = binding
                copy.commands = newValue.components(separatedBy: "\n")
                update(copy)
            },
        )
    }

    private struct Message: View {
        let text: String
        let color: Color

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(text).font(.system(size: 12)).foregroundStyle(KBTheme.textSecondary)
            }
        }
    }
}

struct ShortcutButton: View {
    let notation: String
    let isRecording: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if isRecording {
                    Text("Press keys…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(KBTheme.accentText)
                    Keycap("esc").opacity(0.7)
                } else if notation.isEmpty {
                    Text("Record shortcut")
                        .font(.system(size: 12))
                        .foregroundStyle(KBTheme.textTertiary)
                } else {
                    ForEach(Array(shortcutSymbols(notation).enumerated()), id: \.offset) { _, symbol in
                        Keycap(symbol)
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isRecording ? KBTheme.accent : isHovered ? KBTheme.border : Color.clear, lineWidth: isRecording ? 1.5 : 1),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Click, then press the new shortcut")
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
                Button("Grow") { set("resize smart +50") }
                Button("Shrink") { set("resize smart -50") }
            }
            Menu("Focus & move") {
                ForEach(["left", "right", "up", "down"], id: \.self) { direction in
                    Button("Focus \(direction)") { set("focus \(direction)") }
                }
                Divider()
                ForEach(["left", "right", "up", "down"], id: \.self) { direction in
                    Button("Move window \(direction)") { set("move \(direction)") }
                }
            }
            Menu("AeroSpace") {
                Button("Reload config") { set("reload-config") }
                Button("Enter service mode") { set("mode service") }
                Button("Back to main mode") { set("mode main") }
                Button("Toggle tiling") { set("enable toggle") }
            }
        } label: {
            Label("Actions", systemImage: "bolt")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(KBTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KBTheme.border))
        .help("Pick an action")
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

// MARK: - Small components

struct Keycap: View {
    let symbol: String

    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(KBTheme.textSecondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(KBTheme.raised))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(KBTheme.border))
            .shadow(color: .black.opacity(0.12), radius: 0, x: 0, y: 1)
    }
}

struct KeyHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(KBTheme.textTertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(KBTheme.border))
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KBTheme.textSecondary)
            Text("\(count)")
                .font(.system(size: 12))
                .foregroundStyle(KBTheme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(KBTheme.background)
    }
}

struct SidebarLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(KBTheme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

struct SidebarItem: View {
    let icon: String
    let title: String
    let trailing: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(isSelected ? KBTheme.textPrimary : KBTheme.textTertiary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? KBTheme.textPrimary : KBTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(KBTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? KBTheme.selected : isHovered ? KBTheme.hover : Color.clear),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

struct Hairline: View {
    var vertical: Bool = false

    var body: some View {
        Rectangle()
            .fill(KBTheme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct KBAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentButton(configuration: configuration)
    }

    private struct AccentButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(KBTheme.accent.opacity(configuration.isPressed ? 0.75 : isHovered && isEnabled ? 0.9 : 1)),
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12)))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
        }
    }
}

struct KBGhostButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        GhostButton(configuration: configuration, tint: tint)
    }

    private struct GhostButton: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        @Environment(\.isEnabled) private var isEnabled: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? KBTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(minWidth: 30, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(configuration.isPressed ? KBTheme.selected : isHovered && isEnabled ? KBTheme.hover : Color.clear),
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KBTheme.border))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}
