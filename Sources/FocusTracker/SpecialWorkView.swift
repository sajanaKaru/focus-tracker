import AppKit
import FocusCore
import SwiftUI

/// Every data-migration and script ticket in one place, with buttons that copy their GitHub links by category.
struct SpecialWorkView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var filter = TicketFilter()
    @State private var appliedDefaultSprint = false
    @State private var showDone = false
    @State private var copiedKey: String?

    var body: some View {
        let open = store.tickets(matching: filter).filter { showDone || $0.status != .done }
        let groups = SpecialWork.allCases.map { kind in
            (kind, open.filter { kind.matches($0) }.sorted { $0.updatedAt > $1.updatedAt })
        }
        let total = groups.reduce(0) { $0 + $1.1.count }

        VStack(spacing: 0) {
            FilterBar(filter: $filter, showsRepo: false, showsCount: false)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        PageHeader(title: "Data & Scripts", subtitle: "Tickets labelled Data Migration or Script")
                        Spacer()
                        Toggle("Show done", isOn: $showDone).toggleStyle(.switch).controlSize(.small)
                        copyButton(key: "all", title: "Copy all links", groups: groups, primary: true)
                    }

                    if total == 0 {
                        EmptyHint(
                            text: filter.isActive
                                ? "No Data Migration or Script tickets match the current sprint and milestone."
                                : "No tickets with a Data Migration or Script label.",
                            symbol: "externaldrive"
                        )
                    }

                    ForEach(groups, id: \.0) { kind, tickets in
                        if !tickets.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    SectionTitle(title: kind.title, count: tickets.count)
                                    Spacer()
                                    copyButton(key: kind.rawValue, title: "Copy links", groups: [(kind, tickets)], primary: false)
                                }
                                VStack(spacing: 8) {
                                    ForEach(tickets) { ticket in
                                        TicketRow(ticket: ticket)
                                            .cardStyle(padding: 10, selected: selectedTicketID == ticket.id)
                                            .hoverLift()
                                            .onTapGesture { selectedTicketID = ticket.id }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.pageBackground)
        }
        .task(id: store.hasCurrentSprint) { applyDefaultSprint() }
    }

    /// Once per launch, when a current sprint is known, start on it; later changes are the user's.
    private func applyDefaultSprint() {
        guard !appliedDefaultSprint, store.hasCurrentSprint else { return }
        appliedDefaultSprint = true
        if filter.sprint == .any { filter.sprint = .current }
    }

    @ViewBuilder
    private func copyButton(key: String, title: String, groups: [(SpecialWork, [Ticket])], primary: Bool) -> some View {
        let text = SpecialWork.linkText(for: groups)
        let copied = copiedKey == key
        let button = Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedKey = key
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedKey == key { copiedKey = nil }
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.clipboard")
        }
        .controlSize(.large)
        .disabled(text.isEmpty)
        .help("Copy the GitHub links grouped by category")
        if primary { button.buttonStyle(.primary) } else { button.buttonStyle(.secondary) }
    }
}
