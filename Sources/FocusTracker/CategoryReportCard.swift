import FocusCore
import SwiftUI

struct CategoryReportCard: View {
    @Environment(AppStore.self) private var store
    @State private var period = ReportPeriod.thisMonth
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()

    private func tint(_ category: TicketCategory?) -> Color {
        switch category {
        case .bug: Theme.danger
        case .feature: Theme.accent
        case .customer: Theme.orange
        case .task: Theme.teal
        case .change: Theme.info
        case nil: Theme.slate
        }
    }

    private var interval: DateInterval {
        let range = min(customStart, customEnd)...max(customStart, customEnd)
        return period.interval(now: store.now, custom: range)
    }

    var body: some View {
        let stats = store.categoryStats(in: interval)
        let unique = Set(stats.flatMap { $0.entries.map(\.id) }).count
        let top = stats.map(\.entries.count).max() ?? 0

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "By category", count: unique)
                Spacer()
                if period == .custom {
                    DatePicker("From", selection: $customStart, displayedComponents: .date).labelsHidden()
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date).labelsHidden()
                }
                Picker("Period", selection: $period) {
                    ForEach(ReportPeriod.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if unique == 0 {
                Text("No tickets worked on in this period.").foregroundStyle(.secondary)
            }
            ForEach(stats) { stat in
                row(stat, top: top)
            }

            Text("Counts tickets with time tracked or a note in the period. A ticket with several labels counts in each category.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 18)
    }

    @ViewBuilder
    private func row(_ stat: CategoryStat, top: Int) -> some View {
        let count = stat.entries.count
        DisclosureGroup {
            VStack(spacing: 6) {
                ForEach(stat.entries) { entry in
                    HStack {
                        Text(entry.ticket.title).lineLimit(1)
                        Text(entry.ticket.displayKey).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.short(entry.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(tint(stat.category)).frame(width: 8, height: 8)
                    Text(stat.title).fontWeight(.medium)
                    Spacer()
                    Text("\(count) \(count == 1 ? "ticket" : "tickets")").font(.callout.monospacedDigit())
                    Text("\(stat.doneCount) done").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    Text(Format.short(stat.seconds)).font(.callout.weight(.medium).monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                }
                GeometryReader { proxy in
                    Capsule().fill(tint(stat.category))
                        .frame(width: count == 0 ? 0 : max(4, proxy.size.width * Double(count) / Double(max(top, 1))))
                }
                .frame(height: 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .disabled(count == 0)
    }
}
