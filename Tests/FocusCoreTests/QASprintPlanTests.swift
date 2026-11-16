import XCTest
@testable import FocusCore

@MainActor
final class QASprintPlanTests: XCTestCase {
    private func days(_ n: Double) -> Date { Date(timeIntervalSinceNow: n * 86_400) }
    private func sprint11() -> CustomField { QAPlanFixtures.sprint("Sprint 11", start: days(-14), end: days(-1)) }
    private func sprint12() -> CustomField { QAPlanFixtures.sprint("Sprint 12", start: days(-1), end: days(13)) }

    func testCandidatesRunOldestSprintFirstAndNoSprintLast() {
        let (store, _) = QAPlanFixtures.makeStore()
        let none = QAPlanFixtures.add(store, 1)
        let in12 = QAPlanFixtures.add(store, 2, sprints: [sprint12()])
        let in11 = QAPlanFixtures.add(store, 3, sprints: [sprint11()])

        XCTAssertEqual(store.qaPlanCandidates().map(\.ticket.id), [in11.id, in12.id, none.id])
    }

    func testStateOrderIsKeptInsideASprint() {
        let (store, _) = QAPlanFixtures.makeStore()
        let shared = sprint11()  // one sprint value: two calls would give slightly different end dates
        let ready = QAPlanFixtures.add(store, 1, sprints: [shared])
        let failed = QAPlanFixtures.add(store, 2, sprints: [shared])
        QAPlanFixtures.fail(store, failed)

        XCTAssertEqual(store.qaPlanCandidates().map(\.ticket.id), [failed.id, ready.id])
    }

    func testTicketInTwoSprintsUsesTheOneThatEndsLast() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1, sprints: [sprint11(), sprint12()])

        XCTAssertEqual(store.qaPlanCandidates().first?.sprint?.value, "Sprint 12")
    }

    func testGroupsAreOrderedAndFlagEndedAndCurrentSprints() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1)
        QAPlanFixtures.add(store, 2, sprints: [sprint12()])
        QAPlanFixtures.add(store, 3, cases: 3, sprints: [sprint11()])
        let now = Date()

        let groups = store.qaPlanSprintGroups()
        XCTAssertEqual(groups.map { $0.sprint?.value }, ["Sprint 11", "Sprint 12", nil])
        XCTAssertEqual(groups.map { $0.isEnded(at: now) }, [true, false, false])
        XCTAssertEqual(groups.map { $0.isCurrent(at: now) }, [false, true, false])
        XCTAssertEqual(groups.map(\.estimateMinutes), [30, 10, 10])
    }

    func testAutoPickTakesTheOldestSprintFirst() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1, sprints: [sprint12()])
        let in11 = QAPlanFixtures.add(store, 2, sprints: [sprint11()])

        XCTAssertEqual(QAPlanner.autoPick(store.qaPlanCandidates(), capacityMinutes: 10), [in11.id])
    }
}
