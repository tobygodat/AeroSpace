import Common
import SwiftUI

extension WorkspaceLayout {
    var title: String {
        switch self {
            case .tiles: "Tiles"
            case .dwindle: "Dwindle"
            case .floating: "Floating"
        }
    }

    fileprivate var blurb: String {
        switch self {
            case .tiles: "AeroSpace's tiles and accordions. New windows join the focused window's container."
            case .dwindle: "Hyprland's default. A new window splits the focused window along its longer side."
            case .floating: "Every window floats. Switching back tiles them again."
        }
    }
}

/// Settings → Layouts: the default layout, per-workspace overrides and the shortcut that cycles them.
/// Shown over the bindings column, so it brings its own header and bottom bar
struct LayoutsPane: View {
    @ObservedObject var editor: KeybindingEditorModel
    @ObservedObject private var model: LayoutsPaneModel
    /// nil hides the "Other…" name field
    @State private var otherName: String? = nil
    @State private var otherError: String? = nil
    @FocusState private var isOtherFocused: Bool

    init(editor: KeybindingEditorModel) {
        self.editor = editor
        _model = ObservedObject(wrappedValue: LayoutsPaneModel.forEditor(editor))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let loadError = model.loadError {
                loadErrorView(loadError)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        defaultLayoutSection
                        overridesSection
                        shortcutSection
                    }
                    .padding(.bottom, 20)
                }
            }
            Hairline()
            bottomBar
        }
        .onAppear { model.loadIfClean() }
        .onChange(of: editor.recordingBindingId) { _ in model.recordingEnded() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Layouts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KBTheme.textPrimary)
            Text("How windows are arranged on each workspace. Changes apply as soon as you save.")
                .font(.system(size: 12))
                .foregroundStyle(KBTheme.textTertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    // MARK: Default layout

    private var defaultLayoutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneSectionTitle(title: "Default layout")
            HStack(alignment: .top, spacing: 12) {
                ForEach(WorkspaceLayout.allCases, id: \.self) { layout in
                    LayoutCard(layout: layout, isSelected: model.settings.effectiveDefault == layout) {
                        model.setDefault(layout)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true) // Equal card heights
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    // MARK: Overrides

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Workspace overrides", count: model.settings.overrides.count)
            if model.settings.overrides.isEmpty {
                Text("Every workspace uses the default layout.")
                    .font(.system(size: 12))
                    .foregroundStyle(KBTheme.textTertiary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            ForEach(model.settings.overrides, id: \.workspace) { item in
                OverrideRow(workspace: item.workspace, layout: item.layout) { model.setOverride(item.workspace, $0) }
            }
            addOverrideControl
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var addOverrideControl: some View {
        if otherName != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Workspace name", text: otherNameText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(KBTheme.textPrimary)
                        .padding(.horizontal, 9)
                        .frame(width: 200, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(KBTheme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isOtherFocused ? KBTheme.accent.opacity(0.7) : KBTheme.border))
                        .focused($isOtherFocused)
                        .onAppear { isOtherFocused = true }
                        .onSubmit(addOther)
                        .onExitCommand(perform: closeOther)
                    Button("Add", action: addOther)
                        .buttonStyle(KBAccentButtonStyle())
                        .disabled((otherName ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel", action: closeOther)
                        .buttonStyle(KBGhostButtonStyle())
                }
                if let otherError {
                    InlineMessage(text: otherError, color: KBTheme.danger)
                }
            }
        } else {
            let candidates = model.overrideCandidates
            Menu {
                ForEach(candidates, id: \.self) { name in
                    Button("Workspace \(name)") { _ = model.addOverride(name) }
                }
                if !candidates.isEmpty {
                    Divider()
                }
                Button("Other…") {
                    otherError = nil
                    otherName = ""
                }
            } label: {
                Label("Add override", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KBTheme.border))
            .help("Give one workspace its own layout")
        }
    }

    private var otherNameText: Binding<String> {
        Binding(
            get: { otherName ?? "" },
            set: { newValue in
                otherName = newValue
                otherError = nil
            },
        )
    }

    private func addOther() {
        if let error = model.addOverride(otherName ?? "") {
            otherError = error
        } else {
            closeOther()
        }
    }

    private func closeOther() {
        otherName = nil
        otherError = nil
    }

    // MARK: Shortcut

    private var shortcutSection: some View {
        let binding = model.shortcutBinding
        return VStack(alignment: .leading, spacing: 0) {
            PaneSectionTitle(title: "Shortcut")
            HStack(spacing: 14) {
                Text("Cycle layout")
                    .font(.system(size: 13))
                    .foregroundStyle(KBTheme.textPrimary)
                Spacer(minLength: 16)
                ShortcutButton(
                    notation: binding?.key ?? "",
                    isRecording: binding != nil && editor.recordingBindingId == binding?.id,
                    action: { model.recordShortcut() },
                )
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.shortcutErrors, id: \.self) { error in
                    InlineMessage(text: error, color: KBTheme.danger)
                }
                Text("The Omarchy presets bind it to Super ⇧ T. Any binding can also pick it from Actions → Window → Workspace layout.")
                    .font(.system(size: 11))
                    .foregroundStyle(KBTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
        }
    }

    // MARK: Load error

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
            Button("Try again") { model.reload() }
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
            }
            Spacer()
            Button("Reload") { model.reload() }
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
            .disabled(!model.canSave)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}

// MARK: - Components

/// SectionHeader without a count, for sections that hold one setting
private struct PaneSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(KBTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

private struct LayoutCard: View {
    let layout: WorkspaceLayout
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                LayoutSchematic(layout: layout, isSelected: isSelected)
                    .frame(height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(layout.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(KBTheme.textPrimary)
                    Text(layout.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(KBTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(KBTheme.raised)
                    RoundedRectangle(cornerRadius: 8).fill(isHovered && !isSelected ? KBTheme.hover : Color.clear)
                },
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? KBTheme.accent : KBTheme.border, lineWidth: isSelected ? 1.5 : 1),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tiny picture of a screen arranged the way the layout arranges it
private struct LayoutSchematic: View {
    let layout: WorkspaceLayout
    let isSelected: Bool

    private let gap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch layout {
                case .tiles:
                    HStack(spacing: gap) {
                        cell
                        cell
                        cell
                    }
                case .dwindle:
                    HStack(spacing: gap) {
                        cell
                        VStack(spacing: gap) {
                            cell
                            HStack(spacing: gap) {
                                cell
                                cell
                            }
                        }
                    }
                case .floating:
                    ZStack(alignment: .topLeading) {
                        cell
                            .frame(width: size.width * 0.56, height: size.height * 0.62)
                            .offset(x: size.width * 0.08, y: size.height * 0.04)
                        cell
                            .frame(width: size.width * 0.56, height: size.height * 0.62)
                            .offset(x: size.width * 0.36, y: size.height * 0.34)
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(KBTheme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KBTheme.border))
    }

    /// Opaque, so the front floating window hides the one behind it
    private var cell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(KBTheme.raised)
            RoundedRectangle(cornerRadius: 3).fill(isSelected ? KBTheme.accent.opacity(0.2) : KBTheme.textTertiary.opacity(0.14))
            RoundedRectangle(cornerRadius: 3).strokeBorder(isSelected ? KBTheme.accent.opacity(0.55) : KBTheme.border)
        }
    }
}

private struct OverrideRow: View {
    let workspace: String
    let layout: WorkspaceLayout
    /// nil removes the override
    let onChange: (WorkspaceLayout?) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text("Workspace \(workspace)")
                .font(.system(size: 13))
                .foregroundStyle(KBTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 16)
            Menu {
                Picker("Layout", selection: Binding<WorkspaceLayout?>(get: { layout }, set: { onChange($0) })) {
                    Text("Same as default").tag(WorkspaceLayout?.none)
                    Divider()
                    ForEach(WorkspaceLayout.allCases, id: \.self) { item in
                        Text(item.title).tag(WorkspaceLayout?.some(item))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(layout.title)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(KBTheme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KBTheme.border))
            .help("Layout of workspace \(workspace)")
            Button {
                onChange(nil)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(KBGhostButtonStyle(tint: KBTheme.danger))
            .help("Remove override")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 7).fill(isHovered ? KBTheme.hover : Color.clear))
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }
}

private struct InlineMessage: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text).font(.system(size: 12)).foregroundStyle(KBTheme.textSecondary)
        }
    }
}
