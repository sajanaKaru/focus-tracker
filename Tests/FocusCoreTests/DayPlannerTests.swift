import XCTest
@testable import FocusCore

final class DayPlannerTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private var base: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 9))! }
    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }
    private var day: DateInterval { DateInterval(start: base, end: at(24)) }
    private func span(_ from: Double, _ to: Double) -> DateInterval { DateInterval(start: at(from), end: at(to)) }

    // MARK: Capacity

    func testCapacityWithNoMeetingsAppliesFocusFactor() {
        let result = DayPlanner.capacity(day: day, busy: [], settings: PlanSettings())
        XCTAssertEqual(result.freeMinutes, 480)
        XCTAssertEqual(result.capacityMinutes, 360)
    }

    func testOverlappingBusyIntervalsCountOnce() {
        let settings = PlanSettings(focusFactor: 1)
        let result = DayPlanner.capacity(day: day, busy: [span(9, 10), span(9.5, 10.5)], settings: settings)
        XCTAssertEqual(result.freeMinutes, 480 - 90)
    }

    func testBusyIntervalsAreClippedToTheDay() {
        let settings = PlanSettings(focusFactor: 1)
        let result = DayPlanner.capacity(day: day, busy: [span(-1, 1)], settings: settings)
        XCTAssertEqual(result.freeMinutes, 480 - 60)
    }

    func testFreeTimeNeverGoesBelowZero() {
        let result = DayPlanner.capacity(day: day, busy: [span(8, 20)], settings: PlanSettings())
        XCTAssertEqual(result.freeMinutes, 0)
        XCTAssertEqual(result.capacityMinutes, 0)
    }

    // MARK: Ranking

    private func ticket(
        _ title: String,
        status: TicketStatus = .todo,
        priority: Priority = .none,
        fields: [CustomField]? = nil,
        issueFields: [CustomField]? = nil,
        due: Date? = nil,
        estimate: Int? = nil,
        updated: Double = 0,
        github: GitHubRef? = nil
    ) -> Ticket {
        Ticket(
            title: title, status: status, priority: priority, fields: fields, issueFields: issueFields,
            dueDate: due, estimateMinutes: estimate, updatedAt: at(-1000 + updated), github: github
        )
    }

    private func rank(_ tickets: [Ticket], carried: Set<UUID> = [], tracked: [UUID: Int] = [:]) -> [PlanCandidate] {
        DayPlanner.rank(tickets: tickets, carriedOver: carried, now: at(9), settings: PlanSettings(), calendar: cal, trackedMinutes: tracked)
    }

    func testRankingOrderFollowsSignalStrength() {
        let sprint = CustomField(name: "Sprint", value: "S1", kind: .iteration, project: "P", start: at(-100), end: at(30))
        let carried = ticket("carried")
        let tickets = [
            ticket("plain"),
            ticket("high", priority: .high),
            ticket("doing", status: .inProgress),
            carried,
            ticket("sprint", fields: [sprint]),
            ticket("soon", due: at(24 + 6)),
            ticket("today", due: at(15), updated: 1),
            ticket("overdue", due: at(-48)),
        ]
        let ranked = rank(tickets, carried: [carried.id])
        XCTAssertEqual(ranked.map(\.ticket.title), ["overdue", "today", "carried", "doing", "soon", "sprint", "high", "plain"])
        XCTAssertEqual(ranked.map(\.reason), [.dueNow, .dueNow, .carriedOver, .inProgress, .dueSoon, .sprintEnding, .priority, .open])
    }

    func testRemainingEstimateExcludesTrackedTime() {
        let big = ticket("big", estimate: 1200)
        let spent = ticket("spent", estimate: 60)
        let ranked = rank([big, spent], tracked: [big.id: 180, spent.id: 90])
        let byTitle = Dictionary(uniqueKeysWithValues: ranked.map { ($0.ticket.title, $0) })
        XCTAssertEqual(byTitle["big"]?.estimateMinutes, 1020)
        XCTAssertEqual(byTitle["big"]?.trackedMinutes, 180)
        XCTAssertEqual(byTitle["spent"]?.estimateMinutes, 0)
    }

    func testCurrentSprintTicketsRankAboveOtherOpenWork() {
        let sprint = CustomField(name: "Sprint", value: "S1", kind: .iteration, project: "P", start: at(-100), end: at(24 * 10))
        let ranked = rank([ticket("high", priority: .high), ticket("plain"), ticket("sprint", fields: [sprint])])
        XCTAssertEqual(ranked.map(\.ticket.title), ["sprint", "high", "plain"])
        XCTAssertEqual(ranked.first?.reason, .inSprint)
    }

    func testWithinSameSignalHigherPriorityThenOldestWins() {
        let ranked = rank([
            ticket("new low", priority: .low, updated: 5),
            ticket("old low", priority: .low, updated: 1),
            ticket("urgent", priority: .urgent, updated: 9),
        ])
        XCTAssertEqual(ranked.map(\.ticket.title), ["urgent", "old low", "new low"])
    }

    func testIneligibleTicketsAreExcluded() {
        let closed = GitHubRef(repo: "o/r", number: 1, url: "", remoteClosed: true)
        let ranked = rank([
            ticket("backlog", status: .backlog),
            ticket("done", status: .done),
            ticket("closed", github: closed),
            ticket("ok", status: .inReview),
        ])
        XCTAssertEqual(ranked.map(\.ticket.title), ["ok"])
    }

    func testEstimateFallsBackToDefaultAndIsMarked() {
        let ranked = rank([ticket("own", estimate: 30, updated: 1), ticket("none", updated: 2)])
        XCTAssertEqual(ranked[0].estimateMinutes, 30)
        XCTAssertFalse(ranked[0].estimatedByApp)
        XCTAssertEqual(ranked[1].estimateMinutes, 60)
        XCTAssertTrue(ranked[1].estimatedByApp)
    }

    func testTargetDateIssueFieldCountsAsDueDate() {
        let target = CustomField(name: "Target date", value: "", kind: .date, project: CustomField.issueFieldsGroup, start: at(10))
        let ranked = rank([ticket("t", issueFields: [target])])
        XCTAssertEqual(ranked.first?.reason, .dueNow)
    }

    // MARK: Auto-pick

    func testAutoPickStopsBeforeExceedingCapacity() {
        let ranked = rank([
            ticket("a", priority: .urgent, estimate: 120),
            ticket("b", priority: .high, estimate: 120),
            ticket("c", priority: .low, estimate: 120),
        ])
        let picked = DayPlanner.autoPick(ranked, capacityMinutes: 240)
        XCTAssertEqual(picked, ranked.prefix(2).map(\.id))
        XCTAssertEqual(DayPlanner.plannedMinutes(ranked, ids: Set(picked)), 240)
    }

    func testAutoPickAlwaysKeepsTheFirstCandidate() {
        let ranked = rank([ticket("big", estimate: 600)])
        XCTAssertEqual(DayPlanner.autoPick(ranked, capacityMinutes: 60), ranked.map(\.id))
        XCTAssertEqual(DayPlanner.autoPick([], capacityMinutes: 60), [])
    }

    func testAutoPickTakesOneOversizedContinuationTicketThenStops() {
        let ranked = rank([
            ticket("a", status: .inProgress, estimate: 120, updated: 1),
            ticket("b", status: .inProgress, estimate: 600, updated: 2),
            ticket("c", priority: .high, estimate: 30),
        ])
        XCTAssertEqual(ranked.map(\.ticket.title), ["a", "b", "c"])
        XCTAssertEqual(DayPlanner.autoPick(ranked, capacityMinutes: 240).count, 2)
        XCTAssertEqual(DayPlanner.autoPick(ranked, capacityMinutes: 240), ranked.prefix(2).map(\.id))
    }

    func testAutoPickStillStopsAtAnOversizedNewTicket() {
        let ranked = rank([
            ticket("a", priority: .urgent, estimate: 120),
            ticket("b", priority: .high, estimate: 600),
            ticket("c", priority: .low, estimate: 30),
        ])
        XCTAssertEqual(DayPlanner.autoPick(ranked, capacityMinutes: 240), [ranked[0].id])
    }

    func testPlannedMinutesCapsEachTicketAtTheDaysCapacity() {
        let ranked = rank([ticket("big", estimate: 1200), ticket("small", estimate: 60)])
        let ids = Set(ranked.map(\.id))
        XCTAssertEqual(DayPlanner.plannedMinutes(ranked, ids: ids), 1260)
        XCTAssertEqual(DayPlanner.plannedMinutes(ranked, ids: ids, capacityMinutes: 360), 420)
    }
}
