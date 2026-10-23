import SwiftUI

/// Panes listed under "Settings" in the sidebar of the keybinding editor window. Each pane lives in its own file;
/// adding one is a new case here
enum SettingsPane: String, CaseIterable, Identifiable {
    case workspaces
    case apps
    case superKey = "super-key"

    var id: String { rawValue }

    var title: String {
        switch self {
            case .workspaces: "Workspaces"
            case .apps: "Apps"
            case .superKey: "Super key"
        }
    }

    /// SF Symbol
    var icon: String {
        switch self {
            case .workspaces: "menubar.rectangle"
            case .apps: "square.grid.2x2"
            case .superKey: "capslock"
        }
    }

    @MainActor @ViewBuilder
    func view(editor: KeybindingEditorModel) -> some View {
        switch self {
            case .workspaces: WorkspacesPane(editor: editor)
            case .apps: AppShortcutsPane(editor: editor)
            case .superKey: SuperKeyPane(editor: editor)
        }
    }
}
