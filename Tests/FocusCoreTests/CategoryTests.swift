import XCTest
@testable import FocusCore

@MainActor
final class CategoryTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testMatchesIssueTypeOrLabelCaseInsensitively() {
        XCTAssertTrue(TicketCategory.bug.matches(Ticket(title: "a", labels: ["bug"])))
        XCTAssertTrue(TicketCategory.bug.matches(Ticket(title: "a", issueType: IssueType(name: "Bug"))))
        XCTAssertTrue(TicketCategory.customer.matches(Ticket(title: "a", labels: ["Customer reported"])))
        XCTAssertTrue(TicketCategory.change.matches(Ticket(title: "a", labels: ["UX improvement"])))
        XCTAssertFalse(TicketCategory.task.matches(Ticket(title: "a", labels: ["bug"])))
    }

    func testPeriodIntervals() {
        let now = date(2026, 10, 9)
        let lastMonth = ReportPeriod.lastMonth.interval(now: now, calendar: cal)
        XCTAssertEqual(lastMonth.start, date(2026, 9, 1))
        XCTAssertEqual(lastMonth.end, date(2026, 10, 1))
        XCTAssertEqual(ReportPeriod.thisMonth.interval(now: now, calendar: cal).end, date(2026, 11, 1))
        XCTAssertEqual(ReportPeriod.thisWeek.interval(now: now, calendar: cal).start, date(2026, 10, 5))
        XCTAssertEqual(ReportPeriod.lastWeek.interval(now: now, calendar: cal).start, date(2026, 9, 28))
        XCTAssertEqual(ReportPeriod.last30Days.interval(now: now, calendar: cal).start, date(2026, 9, 10))

        let custom = ReportPeriod.custom.interval(now: now, calendar: cal, custom: date(2026, 10, 1)...date(2026, 10, 3))
        XCTAssertEqual(custom, DateInterval(start: date(2026, 10, 1), end: date(2026, 10, 4)))
    }

    func testCategoryStatsCountWorkedTicketsPerCategory() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        let bug = store.addTicket(title: "bug")
        let both = store.addTicket(title: "both")
        let plain = store.addTicket(title: "plain")
        let idle = store.addTicket(title: "idle")
        store.update(bug.id) { $0.labels = ["bug"] }
        store.update(both.id) { $0.labels = ["bug", "Customer reported"]; $0.status = .done }
        store.update(idle.id) { $0.labels = ["bug"] }

        let end = date(2026, 9, 15)
        for ticket in [bug, both, plain] {
            store.addManualEntry(ticketID: ticket.id, duration: 3600, endingAt: end)
        }
        let stats = store.categoryStats(in: ReportPeriod.lastMonth.interval(now: date(2026, 10, 9), calendar: cal))
        func stat(_ c: TicketCategory?) -> CategoryStat { stats.first { $0.category == c }! }

        XCTAssertEqual(stat(.bug).entries.count, 2)
        XCTAssertEqual(stat(.bug).doneCount, 1)
        XCTAssertEqual(stat(.bug).seconds, 7200)
        XCTAssertEqual(stat(.customer).entries.count, 1)
        XCTAssertEqual(stat(.task).entries.count, 0)
        XCTAssertEqual(stat(nil).entries.map(\.ticket.title), ["plain"])
    }
}
