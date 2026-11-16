import AppKit
import FocusCore
import SwiftUI

struct PMTodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var sheet: TodaySheet?
    @State private var copied = false

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.pmSummaryText(), forType: .string)
        NSPasteboard.general.setString(store.pmSummaryHTML(), forType: .html)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    var body: some View {
        let progress = store.pmSprintProgress()
        let pipeline = store.pmPipeline()
        let risks = store.pmRisks()
        let riskByID = Dictionary(uniqueKeysWithValues: risks.map { ($0.id, $0) })
        let workload = store.pmWorkload()
        let incoming = store.pmIncoming()

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: timeGreeting(store.now), subtitle: store.now.formatted(date: .complete, time: .omitted))
                    Spacer()
                    HStack(spacing: 10) {
                        Button(action: copySummary) {
                            Label(copied ? "Copied" : "Copy status summary", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                        }
                        .buttonStyle(.secondary)
                        .controlSize(.large)
                        .help("Copy a status summary for the team")
                        Button { sheet = .unplanned } label: { Label("Request", systemImage: "bubble.left.fill") }
                            .buttonStyle(.secondary)
                            .controlSize(.large)
                            .help("Log a request that wasn't planned")
                    }
                }

                SyncIssuesCard(selectedTicketID: $selectedTicketID)

                if !store.syncsTeamIssues {
                    EmptyHint(
                        text: "Add repositories in Settings → GitHub to sync the whole team's issues. Until then these cards show only your own tickets.",
                        symbol: "person.2"
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Sprint progress")
                    sprintCard(progress)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Release pipeline")
                    pipelineCard(pipeline)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Blocked & at risk", count: risks.count)
                    if risks.isEmpty {
                        EmptyHint(text: "Nothing overdue, failed or stale.", symbol: "checkmark.circle")
                    } else {
                        TicketListCard(tickets: risks.map(\.ticket), selectedTicketID: $selectedTicketID) { ticket in
                            if let risk = riskByID[ticket.id] { Chip(text: risk.reason.title, color: risk.reason.color) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Workload", count: workload.count)
                    if workload.isEmpty {
                        EmptyHint(text: "No open tickets.", symbol: "person.2")
                    } else {
                        let maxOpen = workload.map(\.open).max() ?? 1
                        VStack(spacing: 0) {
                            ForEach(Array(workload.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider() }
                                workloadRow(row, maxOpen: maxOpen)
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Incoming requests", count: incoming.count)
                    if incoming.isEmpty {
                        EmptyHint(text: "No new requests to triage.", symbol: "tray")
                    } else {
                        TicketListCard(tickets: incoming, selectedTicketID: $selectedTicketID) { ticket in
                            if ticket.isQuickCapture == true { Chip(text: "Quick capture", color: Theme.info) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .todaySheet($sheet)
    }

    @ViewBuilder
    private func sprintCard(_ progress: SprintProgress?) -> some View {
        if let progress {
            let order: [TicketStatus] = [.done, .testing, .inReview, .inProgress, .todo, .backlog]
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(progress.name).font(.headline)
                    Spacer()
                    if let left = progress.daysLeft {
                        Text("\(left) day\(left == 1 ? "" : "s") left").font(.callout).foregroundStyle(.secondary)
                    }
                }
                DashboardBar(segments: order.map { .init(value: progress.byStatus[$0] ?? 0, color: $0.color) })
                HStack {
                    Text("\(progress.done) of \(progress.total) done").font(.callout.monospacedDigit())
                    Spacer()
                    Text(progress.fraction.formatted(.percent.precision(.fractionLength(0)))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                FlowLayout {
                    ForEach(order.filter { (progress.byStatus[$0] ?? 0) > 0 }) { status in
                        Chip(text: "\(status.title) \(progress.byStatus[status] ?? 0)", color: status.color)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        } else {
            EmptyHint(text: "No current sprint or open milestone with tickets.", symbol: "flag")
        }
    }

    private func pipelineCard(_ rows: [PMPipelineRow]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                VStack(spacing: 4) {
                    Text(row.environment.title).font(.callout.weight(.semibold)).foregroundStyle(row.environment.color)
                    Text("\(row.count)").font(.title.weight(.semibold).monospacedDigit())
                    Text(row.environment == .live ? "released" : "\(row.readyToPromote) ready to promote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .cardStyle(padding: 0)
    }

    private func workloadRow(_ row: WorkloadRow, maxOpen: Int) -> some View {
        HStack(spacing: 12) {
            Text(row.assignee)
                .lineLimit(1)
                .foregroundStyle(row.isUnassigned ? Color.secondary : Color.primary)
                .frame(width: 130, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(Theme.accentGradient)
                    .frame(width: max(8, proxy.size.width * CGFloat(row.open) / CGFloat(max(maxOpen, 1))))
            }
            .frame(height: 8)
            Text("\(row.open) open").font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
            Text("\(row.inFlight) in flight").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
            Text(row.estimateMinutes > 0 ? Format.short(TimeInterval(row.estimateMinutes * 60)) : "–")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private extension RiskReason {
    var color: Color {
        switch self {
        case .overdue: Theme.danger
        case .failedQA: Theme.orange
        case .stale: Theme.warning
        }
    }
}
