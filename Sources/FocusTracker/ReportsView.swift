import AppKit
import Charts
import FocusCore
import SwiftUI

struct ReportsView: View {
    @Environment(AppStore.self) private var store
    @State private var copied = false

    var body: some View {
        let totals = store.dailyTotals(days: 7)
        let weekRange = DateInterval(start: totals.first?.day ?? store.now, end: store.now.addingTimeInterval(1))
        let perTicket = store.tickets
            .map { ($0, store.trackedTime(for: $0.id, in: weekRange)) }
            .filter { $0.1 >= 60 }
            .sorted { $0.1 > $1.1 }
        let weekTotal = totals.reduce(0) { $0 + $1.seconds }
        let topSeconds = perTicket.first?.1 ?? 1

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: "Reports", subtitle: "Last 7 days")
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.standupText(), forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy standup summary", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    }
                    .buttonStyle(.primary)
                    .controlSize(.large)
                }

                HStack(spacing: 14) {
                    StatCard(title: "Total this week", value: Format.short(weekTotal), symbol: "clock.fill", tint: Theme.accent)
                    StatCard(title: "Daily average", value: Format.short(weekTotal / 7), symbol: "chart.bar.fill", tint: Theme.teal)
                    StatCard(title: "Tickets worked", value: "\(perTicket.count)", symbol: "checkmark.circle.fill", tint: Theme.success)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Hours per day")
                    Chart(totals, id: \.day) { item in
                        BarMark(
                            x: .value("Day", item.day, unit: .day),
                            y: .value("Hours", item.seconds / 3600)
                        )
                        .foregroundStyle(Theme.accentGradient)
                        .cornerRadius(5)
                    }
                    .chartYAxisLabel("hours")
                    .frame(height: 220)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle(padding: 18)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionTitle(title: "By ticket", count: perTicket.count)
                        Spacer()
                        Text("Total \(Format.short(perTicket.reduce(0) { $0 + $1.1 }))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if perTicket.isEmpty {
                        Text("No time tracked this week.").foregroundStyle(.secondary)
                    }
                    ForEach(perTicket, id: \.0.id) { ticket, seconds in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(ticket.title).lineLimit(1)
                                Text(ticket.displayKey).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(Format.short(seconds)).font(.callout.weight(.medium).monospacedDigit())
                            }
                            GeometryReader { proxy in
                                Capsule().fill(Theme.accentGradient)
                                    .frame(width: max(4, proxy.size.width * seconds / topSeconds))
                            }
                            .frame(height: 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle(padding: 18)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
    }
}
