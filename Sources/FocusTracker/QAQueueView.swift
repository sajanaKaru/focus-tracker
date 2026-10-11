import FocusCore
import SwiftUI

extension QAState {
    var title: String {
        switch self {
        case .noCases: "No test cases"
        case .ready: "Ready to test"
        case .testing: "Testing"
        case .failed: "Failed"
        case .verified: "Verified"
        }
    }

    var color: Color {
        switch self {
        case .noCases: Theme.slate
        case .ready: Theme.info
        case .testing: Theme.warning
        case .failed: Theme.danger
        case .verified: Theme.success
        }
    }
}

struct QAQueueView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var environment: DeploymentEnvironment?

    var body: some View {
        VStack(spacing: 0) {
            environmentBar
            Divider()
            if environment == .live {
                liveArchive
            } else {
                queue
            }
        }
        .background(Theme.pageBackground)
    }

    private var environmentBar: some View {
        HStack(spacing: 8) {
            chip(title: "All", count: store.qaQueue(environment: nil).ready.count, selected: environment == nil) { environment = nil }
            ForEach(DeploymentEnvironment.allCases) { env in
                chip(title: env.title, count: env == .live ? 0 : store.qaQueue(environment: env).ready.count, selected: environment == env) { environment = env }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func chip(title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if count > 0 { Text("\(count)").font(.caption2.weight(.semibold).monospacedDigit()) }
            }
            .font(.callout.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var queue: some View {
        let queue = store.qaQueue(environment: environment)
        let groups: [(QAState, [Ticket])] = [(.ready, queue.ready), (.testing, queue.testing), (.failed, queue.failed), (.verified, queue.verified)]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.0.title) { state, tickets in
                    if !tickets.isEmpty {
                        QAGroup(title: state.title, color: state.color, tickets: tickets, selectedTicketID: $selectedTicketID)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if queue.isEmpty {
                ContentUnavailableView(
                    "Nothing to test",
                    systemImage: "checklist",
                    description: Text(environment.map { "No tickets are deployed to \($0.title)." } ?? "No tickets are in Testing.")
                )
            }
        }
    }

    private var liveArchive: some View {
        let releases = store.liveArchive()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(releases) { release in
                    QAGroup(title: release.milestone ?? "No milestone", color: DeploymentEnvironment.live.color, tickets: release.tickets, selectedTicketID: $selectedTicketID)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if releases.isEmpty {
                ContentUnavailableView("Nothing released yet", systemImage: "shippingbox", description: Text("Tickets whose status is \"Deployed to Live\" appear here, grouped by milestone."))
            }
        }
    }
}

private struct QAGroup: View {
    let title: String
    let color: Color
    let tickets: [Ticket]
    @Binding var selectedTicketID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(tickets.count)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(tickets) { ticket in
                QATicketRow(ticket: ticket)
                    .cardStyle(padding: 10, selected: selectedTicketID == ticket.id)
                    .hoverLift()
                    .onTapGesture { selectedTicketID = ticket.id }
            }
        }
    }
}

private struct QATicketRow: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let environment = ticket.environment
        let bugCount = store.bugs(for: ticket.id).filter { $0.environment == environment }.count
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(ticket.displayKey).font(.caption).foregroundStyle(.secondary)
                    if let environment { Chip(text: environment.title, color: environment.color, symbol: "shippingbox.fill") }
                    Text(store.qaSummary(ticketID: ticket.id, environment: environment).text).font(.caption).foregroundStyle(.secondary)
                    if bugCount > 0 { Chip(text: bugCount == 1 ? "1 bug" : "\(bugCount) bugs", color: Theme.danger, symbol: "ladybug.fill") }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
