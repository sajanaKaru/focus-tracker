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
}
