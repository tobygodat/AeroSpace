import SwiftUI

/// Placeholder: default layout, per-workspace overrides and the cycle shortcut. Implemented in the next step
struct LayoutsPane: View {
    @ObservedObject var editor: KeybindingEditorModel

    var body: some View {
        Text("Layouts")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
