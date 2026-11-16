import FocusCore
import SwiftUI

struct QATodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var sheet: TodaySheet?

    var body: some View {
        let range = store.dayRange(for: store.now)
        let progress = store.qaProgress(in: range)
        let pipeline = store.qaPipeline()
        let retest = store.qaRetestList()
        let retestByID = Dictionary(uniqueKeysWithValues: retest.map { ($0.id, $0) })
        let bugs = store.qaRecentBugs()

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: timeGreeting(store.now), subtitle: store.now.formatted(date: .complete, time: .omitted))
                    Spacer()
                    HStack(spacing: 10) {
                        Button { sheet = .unplanned } label: { Label("Unplanned", systemImage: "bolt.fill") }
                            .buttonStyle(.secondary)
                            .controlSize(.large)
                            .help("Log a bug or request that wasn't planned and start its timer")
                        AddToTodayMenu(sheet: $sheet)
                    }
                }

                SyncIssuesCard(selectedTicketID: $selectedTicketID)

                HStack(spacing: 14) {
                    StatCard(title: "Tracked today", value: Format.short(store.trackedTime(in: range)), symbol: "timer", tint: Theme.accent)
                    StatCard(title: "Cases passed", value: "\(progress.passed)", symbol: "checkmark.circle.fill", tint: Theme.success)
                    StatCard(title: "Cases failed", value: "\(progress.failed)", symbol: "xmark.circle.fill", tint: Theme.danger)
                    StatCard(title: "Verified", value: "\(progress.verified)", symbol: "checkmark.seal.fill", tint: Theme.teal)
                }

                QATestPlanCard(selectedTicketID: $selectedTicketID)

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Test pipeline")
                    pipelineCard(pipeline)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Failed & retest", count: retest.count)
                    if retest.isEmpty {
                        EmptyHint(text: "No failed tickets waiting for a retest.", symbol: "checkmark.circle")
                    } else {
                        TicketListCard(tickets: retest.map(\.ticket), selectedTicketID: $selectedTicketID) { ticket in
                            if let item = retestByID[ticket.id] {
                                HStack(spacing: 6) {
                                    if item.redeployed { Chip(text: "Redeployed", color: Theme.info) }
                                    Chip(text: "\(item.failedCases) failed", color: Theme.danger)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Bugs reported", count: bugs.count)
                    if bugs.isEmpty {
                        EmptyHint(text: "No bugs reported yet.", symbol: "ladybug")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(bugs.enumerated()), id: \.element.id) { index, bug in
                                if index > 0 { Divider() }
                                bugRow(bug)
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                }

                DayTimeLogSection(day: store.now, isToday: true)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .todaySheet($sheet)
    }

    private func pipelineCard(_ pipeline: QAPipeline) -> some View {
        VStack(spacing: 0) {
            ForEach(pipeline.rows) { row in
                HStack(spacing: 8) {
                    Text(row.environment.title).font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading)
                    Chip(text: "Ready \(row.ready)", color: row.ready > 0 ? Theme.info : Theme.slate)
                    Chip(text: "Testing \(row.testing)", color: row.testing > 0 ? Theme.warning : Theme.slate)
                    Chip(text: "Failed \(row.failed)", color: row.failed > 0 ? Theme.danger : Theme.slate)
                    Chip(text: "Verified \(row.verified)", color: row.verified > 0 ? Theme.success : Theme.slate)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
            }
            HStack(spacing: 8) {
                Text("Live").font(.callout.weight(.semibold)).frame(width: 70, alignment: .leading)
                Text("\(pipeline.liveCount) released").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .cardStyle(padding: 0)
    }

    private func bugRow(_ bug: BugReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "ladybug.fill").foregroundStyle(Theme.danger).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(bug.title).lineLimit(1)
                Text(store.ticket(bug.ticketID)?.displayKey ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Chip(text: bug.severity.title, color: Theme.warning)
            switch bug.state {
            case .draft: Chip(text: "Draft", color: Theme.slate)
            case .created: Chip(text: "Created", color: Theme.success)
            case .failed: Chip(text: "Failed to create", color: Theme.danger)
            }
            if let urlString = bug.issueURL, let url = URL(string: urlString), url.scheme == "https" {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open the issue on GitHub")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .selectsTicket(bug.ticketID, selection: $selectedTicketID)
    }
}
