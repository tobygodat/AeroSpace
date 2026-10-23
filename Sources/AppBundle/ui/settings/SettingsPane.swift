import SwiftUI

/// Panes listed under "Settings" in the sidebar of the keybinding editor window. Each pane lives in its own file;
/// adding one is a new case here
enum SettingsPane: String, CaseIterable, Identifiable {
    case workspaces

    var id: String { rawValue }

    var title: String {
        switch self {
            case .workspaces: "Workspaces"
        }
    }

    /// SF Symbol
    var icon: String {
        switch self {
            case .workspaces: "menubar.rectangle"
        }
    }

    @MainActor @ViewBuilder
    func view(editor: KeybindingEditorModel) -> some View {
        switch self {
            case .workspaces: WorkspacesPane(editor: editor)
        }
    }
}
