/// How the windows of one workspace are arranged. Set per workspace with the `workspace-layout` command,
/// `default-workspace-layout` and the `[workspace-layout]` table in the config, or the Layouts settings pane
public enum WorkspaceLayout: String, CaseIterable, Equatable, Sendable {
    /// AeroSpace's tree of tiles and accordions. New windows join the focused window's container
    case tiles
    /// Hyprland's default: a new window splits the focused window's area along its longer side
    case dwindle
    /// Every window floats. Switching away tiles them again
    case floating

    public var next: WorkspaceLayout {
        let all = Self.allCases
        return all[(all.firstIndex(of: self).orDie() + 1) % all.count]
    }
}
