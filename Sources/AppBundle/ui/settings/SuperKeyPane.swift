import Common
import SwiftUI

/// Which key is Super, and moving ⌥ shortcuts to Super. Every change is written to the config file right away
@MainActor
final class SuperKeyPaneModel: ObservableObject {
    @Published private(set) var status: (text: String, isError: Bool)? = nil
    /// Shown selected while its write is in flight
    @Published private(set) var pendingSuperKey: SuperKey? = nil
    /// The bindings the last conversion moved to Super, for Undo
    @Published private(set) var converted: [ModeBindingKey]? = nil

    let editor: KeybindingEditorModel

    init(editor: KeybindingEditorModel) {
        self.editor = editor
    }

    var selected: SuperKey { pendingSuperKey ?? editor.superKeySetting }

    func select(_ superKey: SuperKey) async {
        if superKey == selected { return }
        pendingSuperKey = superKey
        defer { pendingSuperKey = nil }
        report(await editor.editConfig { rewriteSuperKeySetting($0, superKey) }, success: "\(superKey.title) is Super")
    }

    func convertOptionBindings() async {
        var swap: ModifierSwap? = nil
        let result = await editor.editConfig { text in
            readEditableModes(text).flatMap { modes in
                let it = swapBindingModifier("alt", "super", in: modes)
                swap = it
                return rewriteBindings(text, it.modes)
            }
        }
        guard let swap, case .success = result else {
            report(result, success: "")
            return
        }
        if swap.swapped.isEmpty {
            status = ("Nothing to convert: Super already has those keys", true)
            return
        }
        converted = swap.swapped
        let skipped = swap.skipped.isEmpty ? "" : ". Kept \(swap.skipped.map { prettyShortcut($0.key) }.joined(separator: " ")): Super already has those keys"
        report(result, success: "Converted \(count(swap.swapped.count)) to ◆" + skipped)
    }

    func undoConversion() async {
        guard let converted else { return }
        let result = await editor.editConfig { text in
            readEditableModes(text).flatMap { modes in
                rewriteBindings(text, swapBindingModifier("super", "alt", in: modes, only: Set(converted)).modes)
            }
        }
        if case .success = result { self.converted = nil }
        report(result, success: "Back to ⌥")
    }

    private func report(_ result: Result<String, String>, success: String) {
        switch result {
            case .failure(let msg): status = (msg, true)
            case .success: status = (success, false)
        }
    }
}

private func count(_ n: Int) -> String { n == 1 ? "1 shortcut" : "\(n) shortcuts" }

extension SuperKey {
    var title: String {
        switch self {
            case .capsLock: "Caps Lock"
            case .rightCmd: "Right Command"
            case .capsLockOrRightCmd: "Caps Lock or Right Command"
            case .alt: "Option"
            case .cmd: "Command"
        }
    }

    var detail: String {
        switch self {
            case .capsLock: "Hold for Super, tap for Escape. Nothing else on the Mac needs it."
            case .rightCmd: "Hold for Super. Left Command keeps working as Command."
            case .capsLockOrRightCmd: "Either key. The one you press first is Super until you let go of it."
            case .alt: "Clashes with typing: ⌥B types ∫, ⌥E starts an accent, ⌥← jumps a word."
            case .cmd: "Takes over app shortcuts such as ⌘W and ⌘Q."
        }
    }

    var keycaps: [String] {
        switch self {
            case .capsLock: ["⇪"]
            case .rightCmd: ["right ⌘"]
            case .capsLockOrRightCmd: ["⇪", "right ⌘"]
            case .alt: ["⌥"]
            case .cmd: ["⌘"]
        }
    }
}

struct SuperKeyPane: View {
    @ObservedObject private var editor: KeybindingEditorModel
    @StateObject private var model: SuperKeyPaneModel
    @ObservedObject private var runtime = SuperKeyRuntime.shared

    init(editor: KeybindingEditorModel) {
        self.editor = editor
        _model = StateObject(wrappedValue: SuperKeyPaneModel(editor: editor))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Every Omarchy shortcut starts with Super. Shortcuts show it as ◆.")
                        .font(.system(size: 12))
                        .foregroundStyle(KBTheme.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                    Card {
                        ForEach(Array(SuperKey.allCases.enumerated()), id: \.element) { index, option in
                            if index > 0 { Hairline().padding(.leading, 42) }
                            optionRow(option)
                        }
                    }
                    liveStatus
                        .padding(.horizontal, 34)
                        .padding(.top, 10)

                    GroupTitle("Shortcuts").padding(.top, 22)
                    Card { conversionRow }

                    GroupTitle("Permissions").padding(.top, 22)
                    Card { permissionsRow }
                }
                .padding(.bottom, 20)
            }
            Hairline()
            bottomBar
        }
        .onAppear { editor.loadIfClean() }
    }

    private var header: some View {
        HStack {
            Text("Super key")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KBTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private func optionRow(_ option: SuperKey) -> some View {
        OptionRow(option: option, isSelected: model.selected == option) {
            Task.startUnstructured { await model.select(option) }
        }
    }

    private var superBindingCount: Int { bindingsUsingModifier("super", in: editor.savedModes).count }
    private var optionBindingCount: Int { bindingsUsingModifier("alt", in: editor.savedModes).count }

    @ViewBuilder
    private var liveStatus: some View {
        let superKey = model.selected
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if superBindingCount == 0 {
                StatusDot(color: KBTheme.textTertiary)
                Text(superKey.tapSources.isEmpty ? "No shortcut uses ◆ yet." : "No shortcut uses ◆ yet, so \(superKey.title) works as usual.")
                    .foregroundStyle(KBTheme.textTertiary)
            } else if let standsFor = superKey.standsFor {
                StatusDot(color: KBTheme.success)
                Text("◆ shortcuts use \(standsFor == .option ? "⌥ Option" : "⌘ Command").")
                    .foregroundStyle(KBTheme.textSecondary)
            } else {
                switch runtime.status {
                    case .on(let active) where active == superKey:
                        StatusDot(color: KBTheme.success)
                        Text(onText(superKey))
                            .foregroundStyle(KBTheme.textSecondary)
                    case .failed(let message):
                        StatusDot(color: KBTheme.danger)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Super is off: \(message). Caps Lock works as usual.")
                                .foregroundStyle(KBTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Try again") { runtime.retry() }
                                    .buttonStyle(KBGhostButtonStyle())
                                Button("Open Privacy & Security") { openPrivacySettings() }
                                    .buttonStyle(KBGhostButtonStyle())
                            }
                        }
                    default:
                        StatusDot(color: KBTheme.textTertiary)
                        Text("Starts when AeroSpace reloads the config.")
                            .foregroundStyle(KBTheme.textTertiary)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func onText(_ superKey: SuperKey) -> String {
        switch superKey {
            case .capsLock: "On. Hold Caps Lock for Super, tap it for Escape."
            case .rightCmd: "On. Hold Right Command for Super."
            default: "On. Hold Caps Lock or Right Command for Super. Tap Caps Lock for Escape."
        }
    }

    @ViewBuilder
    private var conversionRow: some View {
        if let converted = model.converted {
            row(title: "Converted \(count(converted.count)) to ◆ Super", detail: "Only the shortcuts changed; commands and comments stayed as they were.") {
                Button("Undo") { Task.startUnstructured { await model.undoConversion() } }
                    .buttonStyle(KBGhostButtonStyle())
            }
        } else if optionBindingCount > 0 {
            row(title: "\(count(optionBindingCount)) use ⌥ Option", detail: "Convert them to Super: ⌥⇧1 becomes ◆⇧1. Commands and comments stay as they are.") {
                Button("Convert to ◆ Super") { Task.startUnstructured { await model.convertOptionBindings() } }
                    .buttonStyle(KBAccentButtonStyle())
            }
        } else {
            row(
                title: superBindingCount > 0 ? "\(count(superBindingCount)) use ◆ Super" : "No shortcuts use ⌥ or ◆",
                detail: superBindingCount > 0 ? "Record new ones in the main mode: hold Super and press the keys." : "Load the Omarchy preset from the sidebar to get the full set.",
            ) { EmptyView() }
        }
    }

    private var permissionsRow: some View {
        row(
            title: "Accessibility",
            detail: "Caps Lock and Right Command need it to act as Super. AeroSpace already has it; some Macs also ask for Input Monitoring. Quitting AeroSpace gives Caps Lock back.",
        ) {
            Button("Open Privacy & Security") { openPrivacySettings() }
                .buttonStyle(KBGhostButtonStyle())
        }
    }

    private func row(title: String, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(KBTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(KBTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

/// The warning in the menu bar menu while Super has failed safe
struct SuperKeyMenuWarning: View {
    @ObservedObject private var runtime = SuperKeyRuntime.shared

    var body: some View {
        if case .failed(let message) = runtime.status {
            Button { runtime.retry() } label: {
                Label("Super key is off. Try again", systemImage: "exclamationmark.triangle.fill")
                Text("\(message). Caps Lock works as usual.")
            }
            Divider()
        }
    }
}

@MainActor private func openPrivacySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}

private struct OptionRow: View {
    let option: SuperKey
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? KBTheme.accent : KBTheme.textTertiary.opacity(0.6), lineWidth: isSelected ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(KBTheme.textPrimary)
                        if option == .capsLock {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(KBTheme.accentText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(KBTheme.accent.opacity(0.12)))
                        }
                    }
                    Text(option.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(KBTheme.textTertiary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    ForEach(option.keycaps, id: \.self) { Keycap($0) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isHovered && !isSelected ? KBTheme.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
    }
}
