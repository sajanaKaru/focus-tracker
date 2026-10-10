import XCTest
@testable import FocusCore

@MainActor
final class TodayFilterTests: XCTestCase {
    private func makeStore() -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, tokenProvider: { nil })
    }

    func testHasOpenMilestoneIgnoresClosedAndMissingMilestones() {
        let store = makeStore()
        XCTAssertFalse(store.hasOpenMilestone)

        store.insertTicketForTest(Ticket(title: "No milestone"))
        store.insertTicketForTest(Ticket(title: "Closed", milestone: Milestone(title: "v1", isOpen: false)))
        XCTAssertFalse(store.hasOpenMilestone)

        store.insertTicketForTest(Ticket(title: "Open", milestone: Milestone(title: "v2")))
        XCTAssertTrue(store.hasOpenMilestone)
    }

    func testOngoingFilterKeepsOnlyOpenMilestoneTickets() {
        let open = Ticket(title: "Open", status: .inProgress, milestone: Milestone(title: "v2"))
        let closed = Ticket(title: "Closed", status: .inProgress, milestone: Milestone(title: "v1", isOpen: false))
        let none = Ticket(title: "None", status: .inProgress)
        let filter = TicketFilter(milestone: .ongoing)

        XCTAssertEqual([open, closed, none].filter { filter.matches($0) }.map(\.title), ["Open"])
    }
}
