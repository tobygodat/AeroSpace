import Common
import SwiftUI

/// Settings → Apps: a shortcut that jumps to an app wherever it is (or opens it), and the workspace its windows open on
struct AppShortcutsPane: View {
    @ObservedObject var editor: KeybindingEditorModel
    @ObservedObject private var catalog = AppCatalog.shared
    @State private var isAddingApp = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let loadError = editor.loadError {
                Text(loadError)
                    .font(.system(size: 13))
                    .foregroundStyle(KBTheme.textSecondary)
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Hairline()
            EditorSaveBar(model: editor, hint: "Click a shortcut to record new keys")
        }
        .onAppear {
            catalog.refresh()
            editor.stopRecording()
        }
        .onDisappear { editor.stopRecording() } // Recording takes every key in the window
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Apps")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KBTheme.textPrimary)
            let count = editor.appShortcuts.count
            Text("\(count) \(count == 1 ? "app" : "apps")")
                .font(.system(size: 12))
                .foregroundStyle(KBTheme.textTertiary)
            Spacer()
            Button {
                editor.stopRecording() // So the app search can be typed in
                isAddingApp = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("Add app")
                }
            }
            .buttonStyle(KBAccentButtonStyle())
            .keyboardShortcut("n", modifiers: .command)
            .popover(isPresented: $isAddingApp, arrowEdge: .bottom) {
                AppPicker { target in
                    isAddingApp = false
                    editor.addAppShortcut(target)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Press an app's shortcut to jump to it, on whichever workspace it is. If it isn't open, it opens. Press again to cycle through its windows.")
                    .font(.system(size: 12))
                    .foregroundStyle(KBTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, editor.homeRulesError == nil ? 12 : 4)
                if let homeRulesError = editor.homeRulesError {
                    Text(homeRulesError)
                        .font(.system(size: 11))
                        .foregroundStyle(KBTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                let rows = editor.appShortcuts
                if rows.isEmpty {
                    Text("No app shortcuts yet")
                        .font(.system(size: 13))
                        .foregroundStyle(KBTheme.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                } else {
                    AppColumnsHeader()
                    ForEach(rows) { row in
                        AppShortcutRowView(editor: editor, row: row)
                    }
                }

                let suggestions = editor.appShortcutSuggestions
                if !suggestions.isEmpty {
                    SectionHeader(title: "Suggested", count: suggestions.count).padding(.top, 10)
                    ForEach(suggestions) { suggestion in
                        SuggestionRowView(suggestion: suggestion) { editor.addSuggestion(suggestion) }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }
}

private enum AppColumn {
    static let shortcut: CGFloat = 130
    static let home: CGFloat = 124
    static let trailing: CGFloat = 44
}

private struct AppColumnsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Shortcut").frame(width: AppColumn.shortcut, alignment: .leading)
            Text("Home workspace").frame(width: AppColumn.home, alignment: .leading)
                .help("New windows of the app open on this workspace")
            Color.clear.frame(width: AppColumn.trailing, height: 1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(KBTheme.textTertiary)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

private struct AppShortcutRowView: View {
    @ObservedObject var editor: KeybindingEditorModel
    let row: AppShortcut

    @State private var isHovered = false
    @State private var isChangingApp = false

    var body: some View {
        let isRecording = row.binding.map { editor.recordingBindingId == $0.id } ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    editor.stopRecording() // So the app search can be typed in
                    isChangingApp = true
                } label: {
                    AppLabel(target: row.target)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Change the app")
                .popover(isPresented: $isChangingApp, arrowEdge: .bottom) {
                    AppPicker { target in
                        isChangingApp = false
                        editor.setTarget(target, of: row)
                    }
                }

                ShortcutButton(notation: row.binding?.key ?? "", isRecording: isRecording) { editor.recordShortcut(of: row) }
                    .frame(width: AppColumn.shortcut, alignment: .leading)

                HomeWorkspaceMenu(workspaces: editor.knownWorkspaceNames, selection: row.home?.workspace) {
                    editor.setHome($0, of: row)
                }
                .disabled(editor.homeRulesError != nil)
                .frame(width: AppColumn.home, alignment: .leading)

                Button {
                    editor.removeAppShortcut(row)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(KBGhostButtonStyle(tint: KBTheme.danger))
                .help("Remove the shortcut and the home workspace")
                .opacity(isHovered ? 1 : 0)
                .frame(width: AppColumn.trailing, alignment: .trailing)
            }
            .frame(height: 48)

            if !isRecording, let note {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(note.color).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(note.text).font(.system(size: 11)).foregroundStyle(KBTheme.textSecondary)
                }
                .padding(.leading, 36)
                .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 7).fill(isHovered ? KBTheme.hover : Color.clear))
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }

    private var note: (text: String, color: Color)? {
        guard let binding = row.binding, let mode = editor.mainMode else { return nil }
        if let error = editor.errors(for: binding, in: mode).first { return (error, KBTheme.danger) }
        if let warning = editor.warning(for: binding) { return (warning, KBTheme.caution) }
        return editor.optionCharacterNote(for: binding).map { ($0, KBTheme.caution) }
    }
}

private struct SuggestionRowView: View {
    let suggestion: AppShortcutSuggestion
    let add: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            AppLabel(target: suggestion.target, replaces: suggestion.replaces)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(Array(shortcutSymbols(suggestion.key).enumerated()), id: \.offset) { _, symbol in
                    Keycap(symbol)
                }
            }
            .padding(.horizontal, 5)
            .frame(width: AppColumn.shortcut, alignment: .leading)
            Color.clear.frame(width: AppColumn.home, height: 1)
            Button("Add", action: add)
                .buttonStyle(KBGhostButtonStyle())
                .help(suggestion.replaces.map { "Replaces “\($0)” on these keys" } ?? "Add this shortcut")
                .frame(width: AppColumn.trailing, alignment: .trailing)
        }
        .frame(height: 48)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 7).fill(isHovered ? KBTheme.hover : Color.clear))
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
    }
}

/// Icon, name, and what kind of target it is
private struct AppLabel: View {
    let target: FocusAppTarget
    var replaces: String? = nil
    @ObservedObject private var catalog = AppCatalog.shared

    var body: some View {
        let app = catalog.resolve(target)
        HStack(spacing: 10) {
            Image(nsImage: catalog.icon(app))
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(app == nil ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(app))
                    .font(.system(size: 13))
                    .foregroundStyle(KBTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caption = caption(app) {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(KBTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func title(_ app: AppCatalog.App?) -> String {
        switch target {
            case .defaultBrowser: "Default browser"
            case .defaultTerminal: "Default terminal"
            case .app(let raw): app?.name ?? raw
        }
    }

    private func caption(_ app: AppCatalog.App?) -> String? {
        if let replaces { return "Replaces “\(replaces)”" }
        switch target {
            case .defaultBrowser, .defaultTerminal: return app?.name ?? "None installed"
            case .app: return app == nil ? "Not installed" : nil
        }
    }
}

private struct HomeWorkspaceMenu: View {
    let workspaces: [String]
    let selection: String?
    let select: (String?) -> Void

    var body: some View {
        Menu {
            Picker("Home workspace", selection: Binding(get: { selection }, set: select)) {
                Text("None").tag(String?.none)
                Divider()
                ForEach(workspaces, id: \.self) { name in
                    Text("Workspace \(name)").tag(String?.some(name))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(selection.map { "Workspace \($0)" } ?? "None")
                .foregroundStyle(selection == nil ? KBTheme.textTertiary : KBTheme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(KBTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(KBTheme.border))
        .help("New windows of the app open on this workspace")
    }
}

// MARK: - App picker

/// Searchable list of the default browser, the default terminal and every installed app
struct AppPicker: View {
    let pick: (FocusAppTarget) -> Void
    @ObservedObject private var catalog = AppCatalog.shared
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let choices = self.choices
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(KBTheme.textTertiary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearchFocused)
                    .onSubmit { choices.first.map { pick($0) } }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(choices, id: \.self) { target in
                        PickerRow(target: target) { pick(target) }
                    }
                    if choices.isEmpty {
                        Text("No apps match “\(query)”")
                            .font(.system(size: 12))
                            .foregroundStyle(KBTheme.textTertiary)
                            .padding(16)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 320, height: 380)
        .onAppear {
            if catalog.installed.isEmpty { catalog.refresh() }
            isSearchFocused = true
        }
    }

    private var choices: [FocusAppTarget] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matches = { (text: String) in query.isEmpty || text.localizedCaseInsensitiveContains(query) }
        let defaults: [(FocusAppTarget, String)] = [(.defaultBrowser, "Default browser"), (.defaultTerminal, "Default terminal")]
        return defaults.filter { matches($0.1) || matches(catalog.resolve($0.0)?.name ?? "") }.map(\.0) +
            catalog.installed.filter { matches($0.name) || matches($0.bundleId) }.map { .app($0.bundleId) }
    }

    private struct PickerRow: View {
        let target: FocusAppTarget
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                AppLabel(target: target)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? KBTheme.selected : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }
    }
}
