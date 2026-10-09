import XCTest
@testable import FocusCore

@MainActor
final class LiveDayStoreTests: XCTestCase {
    private func makeStore(everyDay: Bool = true) -> (AppStore, URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        if everyDay { defaults.set(7, forKey: PrefKey.workDays) }
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url, defaults)
    }

    @discardableResult
    private func addTicket(_ store: AppStore, _ title: String, _ priority: Priority, minutes: Int) -> Ticket {
        let ticket = store.addTicket(title: title, priority: priority)
        store.update(ticket.id) { $0.estimateMinutes = minutes }
        return store.ticket(ticket.id)!
    }

    func testDataWithoutLiveDayFieldsStillLoads() throws {
        let id = UUID().uuidString
        let json = """
        {"tickets":[{"id":"\(id)","title":"t","body":"","status":"todo","priority":0,"labels":[],
        "createdAt":"2026-10-09T08:00:00Z","updatedAt":"2026-10-09T08:00:00Z"}],
        "entries":[],"dayPlans":[{"day":"2026-10-09T00:00:00Z","ticketIDs":["\(id)"]}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })

        XCTAssertEqual(store.tickets.count, 1)
        XCTAssertNil(store.tickets[0].isQuickCapture)
        XCTAssertEqual(store.dayPlans[0].ticketIDs.count, 1)
        XCTAssertNil(store.dayPlans[0].createdAt)
        XCTAssertNil(store.dayPlans[0].deferredTicketIDs)
        XCTAssertNil(store.dayPlans[0].ignoredNewTicketIDs)
    }

    // MARK: Quick capture

    func testQuickCaptureCreatesTicketAndStartsTimerOutsideThePlan() throws {
        let (store, url, defaults) = makeStore()
        let planned = addTicket(store, "planned", .none, minutes: 60)
        store.togglePlanned(planned.id, on: Date())

        let ticket = try XCTUnwrap(store.addQuickCapture(kind: .bug, title: "  Login fails  "))
        XCTAssertEqual(ticket.title, "Login fails")
        XCTAssertEqual(ticket.labels, ["Bug"])
        XCTAssertEqual(ticket.isQuickCapture, true)
        XCTAssertTrue(store.isTracking(ticket.id))
        XCTAssertEqual(store.plan(for: Date())?.ticketIDs, [planned.id])

        store.stop()
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        store.addManualEntry(ticketID: ticket.id, duration: 600, endingAt: noon)
        XCTAssertEqual(store.dayLoad(for: Date(), calendarBusy: []).unplannedMinutes, 10)

        let reloaded = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        XCTAssertEqual(reloaded.ticket(ticket.id)?.isQuickCapture, true)
    }

    func testQuickCaptureRejectsEmptyTitle() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.addQuickCapture(kind: .request, title: "   "))
        XCTAssertTrue(store.tickets.isEmpty)
    }

    // MARK: Overload and defer

    func testOverloadOffersTheLowestRankedUnstartedTicketToDefer() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .urgent, minutes: 240)
        let b = addTicket(store, "b", .high, minutes: 240)
        store.ensurePlan(for: Date(), calendarBusy: [])
        store.togglePlanned(b.id, on: Date())

        let load = store.dayLoad(for: Date(), calendarBusy: [])
        XCTAssertEqual(load.remainingTodayMinutes, 360 - 480)
        XCTAssertEqual(store.deferCandidates(for: Date(), calendarBusy: []), [b.id])
        XCTAssertFalse(store.deferCandidates(for: Date(), calendarBusy: []).contains(a.id))
    }

    func testDeferMovesTicketToTomorrowAsCarriedOver() {
        let (store, url, defaults) = makeStore()
        let a = addTicket(store, "a", .urgent, minutes: 120)
        let b = addTicket(store, "b", .high, minutes: 120)
        let c = addTicket(store, "c", .medium, minutes: 120)
        store.ensurePlan(for: Date(), calendarBusy: [])

        store.deferToTomorrow(c.id, from: Date())
        XCTAssertEqual(store.plan(for: Date())?.ticketIDs, [a.id, b.id])
        XCTAssertEqual(store.plan(for: Date())?.deferredTicketIDs, [c.id])

        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertEqual(store.planCandidates(for: tomorrow).first { $0.ticket.id == c.id }?.reason, .carriedOver)

        let reloaded = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        XCTAssertEqual(reloaded.plan(for: Date())?.deferredTicketIDs, [c.id])
    }

    // MARK: New since planning

    private func syncedTicket(_ store: AppStore, _ title: String, createdAfterPlan: Bool = true) -> Ticket {
        let ticket = addTicket(store, title, .none, minutes: 30)
        store.update(ticket.id) {
            $0.github = GitHubRef(repo: "o/r", number: Int.random(in: 1...9_999), url: "https://example.com")
            $0.createdAt = Date().addingTimeInterval(createdAfterPlan ? 60 : -60)
        }
        return store.ticket(ticket.id)!
    }

    func testNewGitHubTicketsAfterPlanningAreListedUntilAddedOrIgnored() {
        let (store, _, _) = makeStore()
        addTicket(store, "existing", .none, minutes: 60)
        store.ensurePlan(for: Date(), calendarBusy: [])

        let bug = syncedTicket(store, "new bug")
        let local = addTicket(store, "local later", .none, minutes: 30)
        XCTAssertEqual(store.newSincePlanning(for: Date()).map(\.id), [bug.id])
        XCTAssertFalse(store.newSincePlanning(for: Date()).contains { $0.id == local.id })

        store.ignoreNew(bug.id, on: Date())
        XCTAssertTrue(store.newSincePlanning(for: Date()).isEmpty)
    }

    func testAddingANewTicketToThePlanRemovesItFromTheStrip() {
        let (store, _, _) = makeStore()
        addTicket(store, "existing", .none, minutes: 60)
        store.ensurePlan(for: Date(), calendarBusy: [])
        let bug = syncedTicket(store, "new bug")

        store.togglePlanned(bug.id, on: Date())
        XCTAssertTrue(store.newSincePlanning(for: Date()).isEmpty)
    }

    func testPlansWithoutCreationTimeShowNoNewTickets() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .none, minutes: 60)
        store.togglePlanned(a.id, on: Date())
        _ = syncedTicket(store, "new bug")
        XCTAssertTrue(store.newSincePlanning(for: Date()).isEmpty)
    }

    func testTicketsSyncedBeforePlanningAreNotNew() {
        let (store, _, _) = makeStore()
        _ = syncedTicket(store, "old bug", createdAfterPlan: false)
        store.ensurePlan(for: Date(), calendarBusy: [])
        XCTAssertTrue(store.newSincePlanning(for: Date()).isEmpty)
    }
}
