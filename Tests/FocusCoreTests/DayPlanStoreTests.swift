import XCTest
@testable import FocusCore

@MainActor
final class DayPlanStoreTests: XCTestCase {
    private func makeStore() -> (AppStore, URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url, defaults)
    }

    @discardableResult
    private func addTicket(_ store: AppStore, _ title: String, _ priority: Priority, minutes: Int) -> Ticket {
        let ticket = store.addTicket(title: title, priority: priority)
        store.update(ticket.id) { $0.estimateMinutes = minutes }
        return store.ticket(ticket.id)!
    }

    func testSettingsDefaultsAndOverrides() {
        let (store, _, defaults) = makeStore()
        XCTAssertEqual(store.planSettings, PlanSettings(workingMinutes: 480, focusFactor: 0.75, defaultEstimateMinutes: 60))

        defaults.set(360, forKey: PrefKey.workingMinutes)
        defaults.set(50, forKey: PrefKey.focusPercent)
        defaults.set(30, forKey: PrefKey.defaultEstimateMinutes)
        XCTAssertEqual(store.planSettings, PlanSettings(workingMinutes: 360, focusFactor: 0.5, defaultEstimateMinutes: 30))
    }

    func testCapacitySubtractsLoggedActivities() {
        let (store, _, _) = makeStore()
        let start = Calendar.current.startOfDay(for: Date())
        store.addActivity(kind: .meeting, title: "Sync", start: start.addingTimeInterval(9 * 3600), end: start.addingTimeInterval(10 * 3600))
        let capacity = store.capacity(for: Date(), calendarBusy: [DateInterval(start: start.addingTimeInterval(9.5 * 3600), end: start.addingTimeInterval(11 * 3600))])
        XCTAssertEqual(capacity.freeMinutes, 480 - 120)
    }

    func testEnsurePlanPicksWithinCapacityAndIsCreatedOnce() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .urgent, minutes: 120)
        let b = addTicket(store, "b", .high, minutes: 120)
        let c = addTicket(store, "c", .medium, minutes: 120)
        addTicket(store, "d", .low, minutes: 120)

        let plan = store.ensurePlan(for: Date(), calendarBusy: [])
        XCTAssertEqual(plan?.ticketIDs, [a.id, b.id, c.id])

        addTicket(store, "e", .urgent, minutes: 30)
        XCTAssertEqual(store.ensurePlan(for: Date(), calendarBusy: [])?.ticketIDs, [a.id, b.id, c.id])
    }

    func testNoPlanIsCreatedWithoutCandidates() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.ensurePlan(for: Date(), calendarBusy: []))
        XCTAssertNil(store.plan(for: Date()))
    }

    func testTogglePlannedAddsAndRemoves() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .none, minutes: 60)
        store.togglePlanned(a.id, on: Date())
        XCTAssertEqual(store.plan(for: Date())?.ticketIDs, [a.id])
        store.togglePlanned(a.id, on: Date())
        XCTAssertEqual(store.plan(for: Date())?.ticketIDs, [])
    }

    func testSuggestPlanRebuildsAnExistingPlan() {
        let (store, _, _) = makeStore()
        let a = addTicket(store, "a", .urgent, minutes: 60)
        let b = addTicket(store, "b", .low, minutes: 60)
        store.togglePlanned(b.id, on: Date())
        XCTAssertEqual(store.suggestPlan(for: Date(), calendarBusy: [])?.ticketIDs, [a.id, b.id])
        XCTAssertEqual(store.dayPlans.count, 1)
    }

    func testUnfinishedTicketsFromEarlierPlanAreCarriedOver() {
        let (store, _, _) = makeStore()
        let carried = addTicket(store, "carried", .none, minutes: 60)
        let finished = addTicket(store, "finished", .none, minutes: 60)
        addTicket(store, "other", .low, minutes: 60)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        store.togglePlanned(carried.id, on: yesterday)
        store.togglePlanned(finished.id, on: yesterday)
        store.setStatus(finished.id, .done)

        let candidates = store.planCandidates(for: Date())
        XCTAssertEqual(candidates.first?.ticket.id, carried.id)
        XCTAssertEqual(candidates.first?.reason, .carriedOver)
        XCTAssertFalse(candidates.contains { $0.ticket.id == finished.id })
    }

    func testPlansPersistAcrossReload() {
        let (store, url, defaults) = makeStore()
        let a = addTicket(store, "a", .none, minutes: 60)
        store.togglePlanned(a.id, on: Date())

        let reloaded = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        XCTAssertEqual(reloaded.plan(for: Date())?.ticketIDs, [a.id])
    }
}
