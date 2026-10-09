import EventKit
import Foundation

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String

    /// Recurring events share an identifier, so the start time is part of the key.
    var key: String { "\(id)|\(start.timeIntervalSince1970)" }
}

enum CalendarError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Calendar access is off. Allow Focus Tracker in System Settings → Privacy & Security → Calendars."
    }
}

@MainActor
final class CalendarService {
    private let eventStore = EKEventStore()

    /// Timed events on `day` that have already started, with in-progress ones cut off at `now`.
    func startedEvents(on day: Date, now: Date = Date()) async throws -> [CalendarEvent] {
        guard try await eventStore.requestFullAccessToEvents() else { throw CalendarError.denied }

        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && $0.startDate <= now && $0.endDate > $0.startDate }
            .sorted { $0.startDate < $1.startDate }
            .map {
                CalendarEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    end: min($0.endDate, now),
                    calendar: $0.calendar.title
                )
            }
    }

    /// Timed events on `day` that the user has not cancelled or declined, as busy intervals.
    func busyIntervals(on day: Date) async throws -> [DateInterval] {
        guard try await eventStore.requestFullAccessToEvents() else { throw CalendarError.denied }

        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

        return eventStore.events(matching: predicate)
            .filter { event in
                let declined = event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
                return !event.isAllDay && event.status != .canceled && !declined && event.endDate > event.startDate
            }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
    }
}
