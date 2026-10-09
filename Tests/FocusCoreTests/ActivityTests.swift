import XCTest
@testable import FocusCore

@MainActor
final class ActivityTests: XCTestCase {
    private func makeStore() -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url)
    }

    private var today: DateInterval {
        let start = Calendar.current.startOfDay(for: Date())
        return DateInterval(start: start, end: start.addingTimeInterval(86_400))
    }

    func testManualActivityCountsInTotalsAndLog() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")
        let end = Date()
        store.addManualEntry(ticketID: t.id, duration: 600, endingAt: end)
        store.addActivity(kind: .call, title: "  ", start: end.addingTimeInterval(-1_800), end: end)

        XCTAssertEqual(store.activityTime(in: today), 1_800, accuracy: 1)
        XCTAssertEqual(store.trackedTime(in: today), 2_400, accuracy: 1)
        XCTAssertEqual(store.activities[0].title, "Call", "blank title falls back to the kind")
        XCTAssertEqual(store.log(in: today).count, 2)
        XCTAssertTrue(store.log(for: t.id).allSatisfy { if case .activity = $0 { false } else { true } })
    }

    func testInvalidRangeIsIgnored() {
        let (store, _) = makeStore()
        let now = Date()
        store.addActivity(kind: .meeting, title: "x", start: now, end: now)
        XCTAssertTrue(store.activities.isEmpty)
    }

    func testLiveActivityAndTicketTimerReplaceEachOther() {
        let (store, _) = makeStore()
        let t = store.addTicket(title: "A")

        store.start(t.id)
        store.startActivity(kind: .meeting, title: "Standup")
        XCTAssertNil(store.activeEntry)
        XCTAssertEqual(store.activeActivity?.title, "Standup")

        store.start(t.id)
        XCTAssertNil(store.activeActivity)
        XCTAssertTrue(store.isTracking(t.id))
        store.stop()
    }

    func testCalendarEventIsImportedOnce() {
        let (store, url) = makeStore()
        let start = Date().addingTimeInterval(-3_600)
        store.addActivity(kind: .meeting, title: "Sync", start: start, end: Date(), calendarEventID: "evt")
        store.addActivity(kind: .meeting, title: "Sync", start: start, end: Date(), calendarEventID: "evt")
        XCTAssertEqual(store.activities.count, 1)
        XCTAssertTrue(store.hasImported(calendarEventID: "evt", start: start))

        let reloaded = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertEqual(reloaded.activities.count, 1)
    }

    func testRunningActivitySurvivesReloadAndStops() {
        let (store, url) = makeStore()
        store.startActivity(kind: .call, title: "Huddle")

        let reloaded = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
        XCTAssertNotNil(reloaded.activeActivity)
        reloaded.stopActivity()
        XCTAssertNil(reloaded.activeActivity)
        store.stopActivity()
    }
}
