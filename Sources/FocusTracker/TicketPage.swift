import FocusCore
import SwiftUI

/// Full-page ticket view: description, QA, comments, details and time in one wide column.
struct TicketPage: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    var onBack: () -> Void
    var onPlan: () -> Void = {}
    var onShowLog: () -> Void = {}

    var body: some View {
        if let ticket = store.ticket(ticketID) {
            Form {
                header(ticket)

                if !ticket.body.isEmpty {
                    Section("Description") { DescriptionView(markdown: ticket.body) }
                }

                if ticket.github != nil {
                    TicketQASection(ticket: ticket).id(ticketID)
                }

                TicketCommentsSection(ticket: ticket, onPlan: onPlan)

                TicketDetailsSection(ticket: ticket)

                if !ticket.specialWork.isEmpty {
                    Section("Work type") {
                        LabeledContent("Special work") {
                            FlowLayout {
                                ForEach(ticket.specialWork) { Chip(text: $0.title, color: Theme.accentEnd, symbol: $0.symbol) }
                            }
                        }
                    }
                }

                if ticket.milestone != nil || !ticket.allFields.isEmpty {
                    GitHubFieldsSection(ticket: ticket)
                }

                TicketTimeLogSection(ticket: ticket)

                TicketHistorySection(ticketID: ticketID, showAll: onShowLog)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .background(Theme.pageBackground)
            .task(id: ticketID) {
                await store.refreshTicket(ticketID)
                await store.loadComments(ticketID)
                await store.loadOptions()
            }
        } else {
            VStack {
                ContentUnavailableView("Ticket not found", systemImage: "questionmark.circle")
                Button("Back", action: onBack)
            }
        }
    }

    private func header(_ ticket: Ticket) -> some View {
        Section {
            Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back (Esc)")
            TitleEditor(ticket: ticket).id(ticketID)
            FlowLayout {
                StatusBadge(status: ticket.status)
                MetaChips(ticket: ticket)
                LabelChips(ticket: ticket, limit: 12)
                TicketSyncMarker(ticketID: ticketID)
            }
            if let gh = ticket.github, let url = URL(string: gh.url) {
                Link(destination: url) { Label("\(gh.repo)#\(gh.number) on GitHub", systemImage: "arrow.up.right.square") }
                if gh.remoteClosed {
                    Text("No longer assigned to you or closed on GitHub.").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Button(action: onPlan) { Label("Plan", systemImage: "checklist") }
        }
    }
}

private struct OpenTicketPageKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}

extension EnvironmentValues {
    var openTicketPage: (UUID) -> Void {
        get { self[OpenTicketPageKey.self] }
        set { self[OpenTicketPageKey.self] = newValue }
    }
}

extension View {
    /// A click selects the ticket; a double-click opens its full page.
    func selectsTicket(_ id: UUID, selection: Binding<UUID?>) -> some View {
        modifier(SelectsTicket(id: id, selection: selection))
    }
}

private struct SelectsTicket: ViewModifier {
    @Environment(\.openTicketPage) private var openPage
    let id: UUID
    @Binding var selection: UUID?

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { openPage(id) }
            .onTapGesture { selection = id }
    }
}
