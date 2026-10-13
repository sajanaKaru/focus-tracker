import XCTest
@testable import FocusCore

@MainActor
final class QAMilestonePlanTests: XCTestCase {
    private func milestone(_ title: String, open: Bool = true, due: Date? = nil) -> Milestone {
        Milestone(title: title, isOpen: open, dueOn: due)
    }

    func testAddingAPlanUsesTheMilestoneDueDateAndPersists() {
        let (store, url) = QAPlanFixtures.makeStore()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        store.addQAMilestonePlan(milestone("Release 2.4", due: due))

        XCTAssertEqual(store.qaActiveMilestonePlans.map(\.milestone), ["Release 2.4"])
        XCTAssertEqual(store.qaActiveMilestonePlans.first?.targetDate, due)

        let (reloaded, _) = QAPlanFixtures.makeStore(url: url)
        XCTAssertEqual(reloaded.qaMilestonePlans.map(\.id), store.qaMilestonePlans.map(\.id))
        XCTAssertEqual(reloaded.qaMilestonePlans.first?.targetDate, due)
    }

    func testAddingTheSameMilestoneTwiceIsIgnoredUntilTheFirstPlanIsArchived() {
        let (store, _) = QAPlanFixtures.makeStore()
        store.addQAMilestonePlan(milestone("R1"))
        store.addQAMilestonePlan(milestone("R1"))
        XCTAssertEqual(store.qaMilestonePlans.count, 1)

        store.archiveQAMilestonePlan(store.qaMilestonePlans[0].id)
        XCTAssertTrue(store.qaActiveMilestonePlans.isEmpty)
        store.addQAMilestonePlan(milestone("R1"))
        XCTAssertEqual(store.qaActiveMilestonePlans.count, 1)
        XCTAssertEqual(store.qaMilestonePlans.count, 2)
    }

    func testPlannableMilestonesListOpenFirstAndSkipActivePlans() {
        let (store, _) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1, milestone: milestone("Release 2.5"))
        QAPlanFixtures.add(store, 2, milestone: milestone("Release 2.4"))
        QAPlanFixtures.add(store, 3, milestone: milestone("Old", open: false))
        QAPlanFixtures.add(store, 4)

        XCTAssertEqual(store.qaPlannableMilestones().map(\.title), ["Release 2.4", "Release 2.5", "Old"])
        store.addQAMilestonePlan(milestone("Release 2.4"))
        XCTAssertEqual(store.qaPlannableMilestones().map(\.title), ["Release 2.5", "Old"])
    }

    func testPlannableMilestonePrefersTheCopyWithADueDate() {
        let (store, _) = QAPlanFixtures.makeStore()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        QAPlanFixtures.add(store, 1, milestone: milestone("R1"))
        QAPlanFixtures.add(store, 2, milestone: milestone("R1", due: due))

        XCTAssertEqual(store.qaPlannableMilestones().first?.dueOn, due)
    }

    func testExcludeRestoreTargetAndArchive() {
        let (store, _) = QAPlanFixtures.makeStore()
        store.addQAMilestonePlan(milestone("R1"))
        let id = store.qaMilestonePlans[0].id
        let ticket = UUID()

        store.excludeFromQAMilestonePlan(id, ticketID: ticket)
        store.excludeFromQAMilestonePlan(id, ticketID: ticket)
        XCTAssertEqual(store.qaMilestonePlans[0].excludedTicketIDs, [ticket])
        store.restoreToQAMilestonePlan(id, ticketID: ticket)
        XCTAssertEqual(store.qaMilestonePlans[0].excludedTicketIDs, [])

        let target = Date(timeIntervalSince1970: 1_800_000_000)
        store.setQAMilestoneTarget(id, target)
        XCTAssertEqual(store.qaMilestonePlans[0].targetDate, target)
        store.setQAMilestoneTarget(id, nil)
        XCTAssertNil(store.qaMilestonePlans[0].targetDate)

        store.archiveQAMilestonePlan(id)
        XCTAssertTrue(store.qaMilestonePlans[0].archived)
    }

    func testLoadsFilesWithoutMilestonePlans() throws {
        let (store, url) = QAPlanFixtures.makeStore()
        QAPlanFixtures.add(store, 1)
        store.addQAMilestonePlan(milestone("R1"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(json["qaMilestonePlans"])
        json["qaMilestonePlans"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let (reloaded, _) = QAPlanFixtures.makeStore(url: url)
        XCTAssertTrue(reloaded.qaMilestonePlans.isEmpty)
        XCTAssertEqual(reloaded.tickets.count, 1)
    }
}
