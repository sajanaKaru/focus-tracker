import XCTest
@testable import FocusCore

final class DayLoadTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private var base: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 9))! }
    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }
    private var day: DateInterval { DateInterval(start: base, end: at(24)) }

    private func ticket(_ title: String, estimate: Int? = nil, status: TicketStatus = .todo) -> Ticket {
        Ticket(title: title, status: status, estimateMinutes: estimate)
    }

    private func entry(_ ticket: Ticket, startHour: Double, minutes: Double) -> TimeEntry {
        TimeEntry(ticketID: ticket.id, start: at(startHour), end: at(startHour).addingTimeInterval(minutes * 60))
    }

    private func load(
        planned: [Ticket], tickets: [Ticket], entries: [TimeEntry] = [], activities: [Activity] = [], capacity: Int = 360
    ) -> DayLoad {
        DayPlanner.load(
            plannedIDs: Set(planned.map(\.id)), tickets: tickets, entries: entries, activities: activities,
            capacityMinutes: capacity, day: day, now: at(12), settings: PlanSettings()
        )
    }

    func testSplitsPlannedAndUnplannedTime() {
        let a = ticket("planned", estimate: 60)
        let b = ticket("off plan")
        let adHoc = Activity(kind: .call, title: "call", start: at(11), end: at(11).addingTimeInterval(600))
        let imported = Activity(kind: .meeting, title: "standup", start: at(8), end: at(9), calendarEventID: "ev")

        let result = load(
            planned: [a], tickets: [a, b],
            entries: [entry(a, startHour: 9, minutes: 30), entry(b, startHour: 10, minutes: 20)],
            activities: [adHoc, imported]
        )

        XCTAssertEqual(result.plannedTrackedMinutes, 30)
        XCTAssertEqual(result.unplannedMinutes, 30)
        XCTAssertEqual(result.remainingPlannedMinutes, 30)
        XCTAssertEqual(result.remainingTodayMinutes, 360 - 50 - 30)
    }

    func testRemainingPlannedWorkNeverGoesNegative() {
        let a = ticket("over estimate", estimate: 30)
        let result = load(planned: [a], tickets: [a], entries: [entry(a, startHour: 9, minutes: 60)])
        XCTAssertEqual(result.remainingPlannedMinutes, 0)
    }

    func testDonePlannedTicketsHaveNoRemainingWork() {
        let a = ticket("done", estimate: 60, status: .done)
        XCTAssertEqual(load(planned: [a], tickets: [a]).remainingPlannedMinutes, 0)
    }

    func testDefaultEstimateIsUsedWhenTicketHasNone() {
        let a = ticket("no estimate")
        XCTAssertEqual(load(planned: [a], tickets: [a]).remainingPlannedMinutes, 60)
    }

    func testEarlierDaysReduceRemainingWorkButNotTodaysTime() {
        let a = ticket("long running", estimate: 60)
        let result = load(planned: [a], tickets: [a], entries: [entry(a, startHour: -24, minutes: 30)])
        XCTAssertEqual(result.plannedTrackedMinutes, 0)
        XCTAssertEqual(result.remainingPlannedMinutes, 30)
    }

    func testOverloadWhenPlannedWorkExceedsCapacity() {
        let a = ticket("a", estimate: 60)
        let b = ticket("b", estimate: 60)
        let result = load(planned: [a, b], tickets: [a, b], capacity: 60)
        XCTAssertEqual(result.remainingTodayMinutes, -60)
        XCTAssertTrue(result.isOverloaded)
        XCTAssertEqual(result.overloadMinutes, 60)
    }

    func testOneMultiDayTicketFillsTheDayWithoutOverloading() {
        let big = ticket("big", estimate: 1200)
        let result = load(planned: [big], tickets: [big])
        XCTAssertEqual(result.remainingPlannedMinutes, 360)
        XCTAssertEqual(result.remainingTodayMinutes, 0)
        XCTAssertFalse(result.isOverloaded)
    }

    func testMultiDayTicketAllocationShrinksAsTheDayIsWorked() {
        let big = ticket("big", estimate: 1200)
        let result = load(planned: [big], tickets: [big], entries: [entry(big, startHour: 9, minutes: 120)])
        XCTAssertEqual(result.remainingPlannedMinutes, 240)
        XCTAssertEqual(result.remainingTodayMinutes, 0)
        XCTAssertFalse(result.isOverloaded)
    }

    func testNotOverloadedHasZeroOverload() {
        let a = ticket("small", estimate: 30)
        let result = load(planned: [a], tickets: [a])
        XCTAssertFalse(result.isOverloaded)
        XCTAssertEqual(result.overloadMinutes, 0)
    }

    // MARK: Defer

    private func candidate(_ ticket: Ticket, minutes: Int) -> PlanCandidate {
        PlanCandidate(ticket: ticket, reason: .open, estimateMinutes: minutes, estimatedByApp: false)
    }

    func testDeferTakesLowestRankedUntilOverloadIsCovered() {
        let a = ticket("a"), b = ticket("b"), c = ticket("c")
        let ranked = [candidate(a, minutes: 60), candidate(b, minutes: 60), candidate(c, minutes: 60)]
        let ids = DayPlanner.deferCandidates(ranked, plannedIDs: [a.id, b.id, c.id], startedIDs: [], overloadMinutes: 90)
        XCTAssertEqual(ids, [c.id, b.id])
    }

    func testDeferSkipsStartedAndUnplannedTickets() {
        let a = ticket("a"), b = ticket("b"), c = ticket("c"), d = ticket("d")
        let ranked = [candidate(a, minutes: 60), candidate(b, minutes: 60), candidate(c, minutes: 60), candidate(d, minutes: 60)]
        let ids = DayPlanner.deferCandidates(ranked, plannedIDs: [a.id, b.id, c.id], startedIDs: [b.id], overloadMinutes: 90)
        XCTAssertEqual(ids, [c.id, a.id])
    }

    func testDeferIsEmptyWithoutOverload() {
        let a = ticket("a")
        XCTAssertEqual(DayPlanner.deferCandidates([candidate(a, minutes: 60)], plannedIDs: [a.id], startedIDs: [], overloadMinutes: 0), [])
    }
}
