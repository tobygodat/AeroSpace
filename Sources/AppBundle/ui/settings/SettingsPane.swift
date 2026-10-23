import SwiftUI

/// Panes listed under "Settings" in the sidebar of the keybinding editor window. Each pane lives in its own file;
/// adding one is a new case here
enum SettingsPane: String, CaseIterable, Identifiable {
    case layouts

    var id: String { rawValue }

    var title: String {
        switch self {
            case .layouts: "Layouts"
        }
    }

    /// SF Symbol
    var icon: String {
        switch self {
            case .layouts: "rectangle.split.2x2"
        }
    }

    @MainActor @ViewBuilder
    func view(editor: KeybindingEditorModel) -> some View {
        switch self {
            case .layouts: LayoutsPane(editor: editor)
        }
    }
}
