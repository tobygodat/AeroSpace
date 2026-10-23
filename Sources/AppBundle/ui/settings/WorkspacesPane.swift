import Common
import OrderedCollections
import SwiftUI

/// Workspace count and workspace bar options. Every change is written to the config file right away
@MainActor
final class WorkspacesPaneModel: ObservableObject {
    @Published private(set) var settings: WorkspaceSettings? = nil
    @Published private(set) var status: (text: String, isError: Bool)? = nil

    let editor: KeybindingEditorModel
    private var pendingChanges = 0

    init(editor: KeybindingEditorModel) {
        self.editor = editor
    }

    func load() {
        guard let config = readConfig() else { return }
        settings = readWorkspaceSettings(config.text)
    }

    /// Applies `change` to the settings in the file as it is when the write happens, so edits made elsewhere survive
    func change(_ change: (inout WorkspaceSettings) -> Void) async {
        guard var shown = settings else { return }
        change(&shown)
        if shown == settings { return }
        settings = shown
        pendingChanges += 1
        defer { pendingChanges -= 1 }
        var rewrite: WorkspaceSettingsRewrite? = nil
        let result = await editor.editConfig { text in
            var desired = readWorkspaceSettings(text)
            change(&desired)
            return rewriteWorkspaceSettings(text, desired).map {
                rewrite = $0
                return $0.text
            }
        }
        switch result {
            case .failure(let msg):
                status = (msg, true)
                if pendingChanges == 1 { load() }
            case .success(let text):
                if pendingChanges == 1 { settings = readWorkspaceSettings(text) }
                guard let rewrite, let url = editor.configFileUrl else { return }
                let added = rewrite.addedHotkeys.isEmpty ? [] : ["Added " + rewrite.addedHotkeys.map(prettyShortcut).joined(separator: " ")]
                status = ((["Saved to \(url.displayPath)"] + added + rewrite.notes).joined(separator: ". "), false)
        }
    }

    private func readConfig() -> (url: URL, text: String)? {
        if editor.configFileUrl == nil { editor.load() }
        guard let url = editor.configFileUrl else {
            status = (editor.loadError ?? "Can't find the config file", true)
            return nil
        }
        guard let text = try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8) else {
            status = ("Can't read \(url.displayPath)", true)
            return nil
        }
        return (url, text)
    }
}

struct WorkspacesPane: View {
    @StateObject private var model: WorkspacesPaneModel
    /// Redraws the bar preview when windows open, close, or move
    @ObservedObject private var tray = TrayMenuModel.shared

    init(editor: KeybindingEditorModel) {
        _model = StateObject(wrappedValue: WorkspacesPaneModel(editor: editor))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let settings = model.settings {
                        barPreview(settings)
                        form(settings)
                    }
                }
                .padding(.bottom, 20)
            }
            Hairline()
            bottomBar
        }
        .onAppear { model.load() }
    }

    private var header: some View {
        HStack {
            Text("Workspaces")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KBTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    /// The real bar with the apps on each workspace now, laid out for the chosen settings
    private func barPreview(_ settings: WorkspaceSettings) -> some View {
        HStack(spacing: 0) {
            Text("Menu bar")
                .font(.system(size: 11))
                .foregroundStyle(KBTheme.textTertiary)
            Spacer(minLength: 16)
            InlineWorkspaceBar(
                items: workspaceBarItems(liveWorkspaceBarWorkspaces(), persistent: OrderedSet(settings.persistentWorkspaces)),
                appIcons: settings.appIcons,
                maxWidth: workspaceBarMaxWidth(),
            )
                .clipped()
                .opacity(settings.barEnabled ? 1 : 0.35)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(KBTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(KBTheme.border))
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func form(_ settings: WorkspaceSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Workspaces")
                            .font(.system(size: 13))
                            .foregroundStyle(KBTheme.textPrimary)
                        Text("Always shown in the menu bar, even when empty.")
                            .font(.system(size: 12))
                            .foregroundStyle(KBTheme.textTertiary)
                    }
                    Spacer(minLength: 16)
                    WorkspaceCountPicker(count: settings.count) { count in change { $0.count = count } }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 58)
            }
            if settings.count > 0 {
                let range = settings.count == 1 ? "1" : "1–\(settings.count)"
                Text("Super + \(range) switches · Super + Shift + \(range) moves the focused window")
                    .font(.system(size: 12))
                    .foregroundStyle(KBTheme.textTertiary)
                    .padding(.horizontal, 34)
                    .padding(.top, 8)
            }
            if !settings.otherPersistent.isEmpty {
                HStack(spacing: 6) {
                    Text("Also always shown: \(settings.otherPersistent.joined(separator: ", "))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(KBTheme.textTertiary)
                    Button("Remove") { change { $0.otherPersistent = [] } }
                        .buttonStyle(.plain)
                        .foregroundStyle(KBTheme.accentText)
                        .help("Keep only workspaces 1–\(settings.count) always in the menu bar")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 34)
                .padding(.top, 4)
            }

            GroupTitle("Menu bar").padding(.top, 22)
            Card {
                ToggleRow(title: "Show workspaces in the menu bar", isOn: settings.barEnabled) { isOn in change { $0.barEnabled = isOn } }
                Hairline().padding(.leading, 14)
                ToggleRow(title: "Show app icons", isOn: settings.appIcons) { isOn in change { $0.appIcons = isOn } }
                .disabled(!settings.barEnabled)
            }
        }
    }

    private func change(_ change: @escaping @MainActor (inout WorkspaceSettings) -> Void) {
        Task.startUnstructured { await model.change(change) }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let status = model.status {
                StatusDot(color: status.isError ? KBTheme.danger : KBTheme.success)
                Text(status.text)
                    .foregroundStyle(status.isError ? KBTheme.danger : KBTheme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(status.text)
            } else {
                Text("Changes are saved to the config file right away")
                    .foregroundStyle(KBTheme.textTertiary)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}

private struct GroupTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(KBTheme.textSecondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
    }
}

/// A rounded box around rows, like a grouped form
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 8).fill(KBTheme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(KBTheme.border))
            .padding(.horizontal, 20)
    }
}

private struct ToggleRow: View {
    let title: String
    let isOn: Bool
    let set: @MainActor (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isEnabled ? KBTheme.textPrimary : KBTheme.textTertiary)
            Spacer()
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .tint(KBTheme.accent)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

/// Digits 1-9 in one segmented row. Workspaces up to the selected count are lit, the way the menu bar will show them
private struct WorkspaceCountPicker: View {
    let count: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1 ... 9, id: \.self) { n in
                Button { select(n) } label: {
                    Text("\(n)")
                        .font(.system(size: 12, weight: n == count ? .semibold : .medium).monospacedDigit())
                        .foregroundStyle(n == count ? Color.white : n < count ? KBTheme.textPrimary : KBTheme.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(n == count ? KBTheme.accent : Color.clear),
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n) \(n == 1 ? "workspace" : "workspaces")")
                .accessibilityAddTraits(n == count ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(KBTheme.background))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(KBTheme.border))
    }
}
