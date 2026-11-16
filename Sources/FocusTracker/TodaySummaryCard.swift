import AppKit
import FocusCore
import SwiftUI

/// In-app live summary preview card displaying categorized tickets, activities, and notes with one-click copy.
struct TodaySummaryCard: View {
    @Environment(AppStore.self) private var store
    let day: Date
    @Binding var selectedTicketID: UUID?
    @State private var isExpanded: Bool = true
    @State private var copied: Bool = false

    private var isToday: Bool { Calendar.current.isDate(day, inSameDayAs: store.now) }
    private var range: DateInterval { store.dayRange(for: day) }

    private var dayLabel: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        if Calendar.current.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            store.daySummaryText(for: day, includeDate: true, includeTomorrow: isToday),
            forType: .string
        )
        NSPasteboard.general.setString(
            store.daySummaryHTML(for: day, includeDate: true, includeTomorrow: isToday),
            forType: .html
        )
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    var body: some View {
        let sections = store.daySummarySections(for: day)
        let totalItems = sections.map(\.items.count).reduce(0, +)
        let totalTracked = store.trackedTime(in: range) + store.activityTime(in: range)

        VStack(alignment: .leading, spacing: 14) {
            // Header with metrics and actions
            HStack(spacing: 10) {
                IconTile(symbol: "doc.text.fill", tint: Theme.accent, size: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(dayLabel)'s Summary")
                            .font(.headline.weight(.semibold))

                        if totalItems > 0 {
                            Chip(text: "\(totalItems) \(totalItems == 1 ? "item" : "items")", color: Theme.accent)
                        }

                        if totalTracked >= 60 {
                            Text("· \(Format.short(totalTracked))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(day.formatted(date: .complete, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Quick copy button with visual checkmark feedback
                Button(action: copySummary) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                            .foregroundStyle(copied ? Theme.success : Color.primary)
                        Text(copied ? "Copied!" : "Copy Summary")
                            .foregroundStyle(copied ? Theme.success : Color.primary)
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.secondary)
                .help("Copy formatted summary to clipboard (⌘-ready for Slack, Mail, Jira)")

                // Expand / Collapse toggle
                Button {
                    withAnimation(.spring(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse summary preview" : "Expand summary preview")
                .accessibilityLabel(isExpanded ? "Collapse summary preview" : "Expand summary preview")
            }

            // Expanded preview body
            if isExpanded {
                Divider()

                if sections.isEmpty {
                    EmptyHint(
                        text: isToday ? "No tickets or activities tracked yet today. Items will appear here as time is logged." : "No tickets or activities tracked on this day.",
                        symbol: "doc.plaintext"
                    )
                    .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sections, id: \.title) { section in
                            sectionView(section)
                        }

                        if isToday {
                            tomorrowPreview
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .cardStyle(padding: 16)
    }

    @ViewBuilder
    private func sectionView(_ section: SummarySection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.callout.weight(.bold))
                Text("\(section.items.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                    itemView(item)
                }
            }
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func itemView(_ item: SummaryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Theme.accent)

                if item.isLink, let url = URL(string: item.text), url.scheme == "https" || url.scheme == "http" {
                    Link(destination: url) {
                        Text(item.text)
                            .font(.callout)
                            .underline()
                    }
                } else {
                    Text(item.text)
                        .font(.callout)
                }
            }

            if !item.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(item.notes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Text("-")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private var tomorrowPreview: some View {
        let calendar = Calendar.current
        let nextDay = store.planSettings.nextWorkingDay(after: day, calendar: calendar)
        let isNextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)).map { calendar.isDate($0, inSameDayAs: nextDay) } ?? false
        let label = isNextDay ? "Tomorrow" : nextDay.formatted(.dateTime.weekday(.wide))

        let ids = store.plan(for: nextDay, calendar: calendar)?.ticketIDs ?? DayPlanner.autoPick(
            store.planCandidates(for: nextDay, calendar: calendar),
            capacityMinutes: store.capacity(for: nextDay, calendarBusy: [], calendar: calendar).capacityMinutes
        )
        let plannedTickets = ids.compactMap { store.ticket($0) }.filter { $0.status != .done }

        if !plannedTickets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.callout.weight(.bold))
                    Text("\(plannedTickets.count) planned")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plannedTickets) { ticket in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.body.weight(.bold))
                                .foregroundStyle(Theme.warning)
                            Text("\(ticket.displayKey) \(ticket.title)")
                                .font(.callout)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}
