import FocusCore
import SwiftUI

struct WorkspaceSwitcher: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let active = store.activeWorkspace
        Menu {
            Picker("Workspace", selection: Binding(get: { active }, set: { store.selectedWorkspace = $0 })) {
                ForEach(store.workspaceOptions, id: \.self) { workspace in
                    Label(workspace.title, systemImage: Self.symbol(workspace)).tag(workspace)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(active)).foregroundStyle(Theme.accent)
                Text(active.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Switch between personal and organization workspaces")
    }

    private static func symbol(_ workspace: Workspace) -> String {
        switch workspace {
        case .all: "square.grid.2x2"
        case .personal: "person.fill"
        case .organization: "building.2.fill"
        }
    }
}
