import FocusCore
import SwiftUI

struct FilterBar: View {
    @Environment(AppStore.self) private var store
    @Binding var filter: TicketFilter

    var body: some View {
        HStack(spacing: 8) {
            repoMenu
            milestoneMenu
            sprintMenu
            Spacer()
            if filter.isActive {
                Text("\(store.tickets(matching: filter).count) of \(store.tickets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Clear") { filter = TicketFilter() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.pageBackground)
    }

    private var repoMenu: some View {
        Menu {
            Picker("Repository", selection: $filter.repo) {
                Text("All repositories").tag(String?.none)
                Divider()
                ForEach(store.repoNames, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            FilterLabel(title: filter.repo ?? "Repository", symbol: "shippingbox", active: filter.repo != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var milestoneMenu: some View {
        Menu {
            Picker("Milestone", selection: $filter.milestone) {
                Text("All milestones").tag(TicketFilter.MilestoneChoice.any)
                Text("Ongoing (open)").tag(TicketFilter.MilestoneChoice.ongoing)
                Text("No milestone").tag(TicketFilter.MilestoneChoice.none)
                Divider()
                ForEach(store.milestoneTitles, id: \.self) { Text($0).tag(TicketFilter.MilestoneChoice.named($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            FilterLabel(title: milestoneTitle, symbol: "flag.checkered", active: filter.milestone != .any)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sprintMenu: some View {
        Menu {
            Picker("Sprint", selection: $filter.sprint) {
                Text("All sprints").tag(TicketFilter.SprintChoice.any)
                Text("Current sprint").tag(TicketFilter.SprintChoice.current)
                Text("No sprint").tag(TicketFilter.SprintChoice.none)
                Divider()
                ForEach(store.sprintNames, id: \.self) { Text($0).tag(TicketFilter.SprintChoice.named($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            FilterLabel(title: sprintTitle, symbol: "repeat", active: filter.sprint != .any)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var milestoneTitle: String {
        switch filter.milestone {
        case .any: "Milestone"
        case .ongoing: "Ongoing milestone"
        case .none: "No milestone"
        case .named(let title): title
        }
    }

    private var sprintTitle: String {
        switch filter.sprint {
        case .any: "Sprint"
        case .current: "Current sprint"
        case .none: "No sprint"
        case .named(let name): name
        }
    }
}

private struct FilterLabel: View {
    let title: String
    let symbol: String
    let active: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(active ? Theme.accent : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Theme.accent.opacity(0.12) : Theme.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Theme.accent.opacity(0.35) : Color.primary.opacity(0.08)))
    }
}
