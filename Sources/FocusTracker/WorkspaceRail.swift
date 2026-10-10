import FocusCore
import SwiftUI

/// Slack-style vertical rail: one tile per workspace, tinted lightly so it blends with the sidebar.
struct WorkspaceRail: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let active = store.activeWorkspace
        VStack(spacing: 12) {
            ForEach(store.workspaceOptions, id: \.self) { workspace in
                WorkspaceTile(workspace: workspace, login: store.githubLogin, selected: workspace == active) {
                    withAnimation(.snappy(duration: 0.2)) { store.selectedWorkspace = workspace }
                }
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.05))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1) }
    }
}

private struct WorkspaceTile: View {
    let workspace: Workspace
    let login: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let palette: [Color] = [Theme.accent, Theme.teal, Theme.orange, Theme.info, Theme.danger, Theme.success]

    private var label: String {
        switch workspace {
        case .all: ""
        case .personal: String((login ?? "Me").prefix(1)).uppercased()
        case .organization(let name): String(name.prefix(2)).uppercased()
        }
    }

    private var tint: Color {
        let name = workspace.title.lowercased()
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[hash % Self.palette.count]
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: selected ? 13 : 18, style: .continuous) }

    var body: some View {
        Button(action: action) {
            ZStack {
                if workspace == .all {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 17, weight: .semibold))
                } else {
                    Text(label).font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(workspace == .all ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(tint.gradient), in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1).padding(selected ? -4 : 0))
            .scaleEffect(hovering && !selected ? 1.05 : 1)
            .opacity(selected || hovering ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .frame(width: 72)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(Theme.accent)
                .frame(width: 4, height: selected ? 28 : (hovering ? 12 : 0))
                .offset(x: -2)
        }
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .help(workspace.title)
        .accessibilityLabel(workspace.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
