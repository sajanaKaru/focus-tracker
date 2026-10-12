import FocusCore
import SwiftUI

enum TicketPageTab: String, CaseIterable, Identifiable {
    case tests, plans, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tests: "Test cases"
        case .plans: "Plans"
        case .notes: "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .tests: "checklist"
        case .plans: "list.bullet.clipboard"
        case .notes: "note.text"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .tests: "1"
        case .plans: "2"
        case .notes: "3"
        }
    }
}

/// Full-page ticket view with three areas: test cases, plans and notes.
struct TicketPage: View {
    @Environment(AppStore.self) private var store
    @AppStorage("ticketPageTab") private var tabRaw = TicketPageTab.tests.rawValue
    let ticketID: UUID
    var onBack: () -> Void
    var onPlan: () -> Void = {}

    private var tab: TicketPageTab { TicketPageTab(rawValue: tabRaw) ?? .tests }

    var body: some View {
        if let ticket = store.ticket(ticketID) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    header(ticket)
                    tabBar
                }
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .tests: TicketTestCasesTab(ticket: ticket)
                        case .plans: TicketPlansTab(ticket: ticket)
                        case .notes: TicketNotesTab(ticket: ticket)
                        }
                    }
                    .id(tab)
                    .frame(maxWidth: 960)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
            .background(Theme.pageBackground)
            .task(id: ticketID) {
                await store.refreshTicket(ticketID)
                await store.loadOptions()
            }
        } else {
            VStack {
                ContentUnavailableView("Ticket not found", systemImage: "questionmark.circle")
                Button("Back", action: onBack)
            }
        }
    }

    private func count(_ tab: TicketPageTab) -> Int {
        switch tab {
        case .tests: store.testCases(for: ticketID).count
        case .plans: store.planComments(for: ticketID).count
        case .notes: store.notes.filter { $0.ticketID == ticketID }.count
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(TicketPageTab.allCases) { item in
                let selected = item == tab
                Button { tabRaw = item.rawValue } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                        Text(item.title)
                        Text("\(count(item))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(selected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(item.key, modifiers: .command)
                .help("\(item.title) (⌘\(String(describing: item.key.character)))")
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? Theme.accent : Color.clear).frame(height: 2)
                }
            }
            Spacer()
        }
    }

    private func header(_ ticket: Ticket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Back (Esc)")
                Spacer()
                if let gh = ticket.github, let url = URL(string: gh.url) {
                    Link(destination: url) { Label("\(gh.repo)#\(gh.number)", systemImage: "arrow.up.right.square") }
                        .font(.callout)
                }
                Button(action: onPlan) { Label("Plan page", systemImage: "checklist") }
                    .buttonStyle(.borderless)
                    .help("Open the full plan page")
            }
            TitleEditor(ticket: ticket).id(ticketID)
            FlowLayout {
                StatusBadge(status: ticket.status)
                MetaChips(ticket: ticket)
                LabelChips(ticket: ticket, limit: 12)
                TicketSyncMarker(ticketID: ticketID)
            }
            if let gh = ticket.github, gh.remoteClosed {
                Text("No longer assigned to you or closed on GitHub.").font(.caption).foregroundStyle(Theme.warning)
            }
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
