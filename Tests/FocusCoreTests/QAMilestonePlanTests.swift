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

    func testProgressCountsStatesEstimateAndSkipsOtherMilestonesAndExclusions() {
        let (store, _) = QAPlanFixtures.makeStore()
        let r1 = milestone("R1")
        let failed = QAPlanFixtures.add(store, 1, cases: 1, milestone: r1)
        QAPlanFixtures.fail(store, failed)
        let testing = QAPlanFixtures.add(store, 2, cases: 2, milestone: r1)
        store.setResult(caseID: store.testCases(for: testing.id)[0].id, environment: .beta, status: .pass)
        QAPlanFixtures.add(store, 3, cases: 3, milestone: r1)
        let verified = QAPlanFixtures.add(store, 4, cases: 1, milestone: r1)
        QAPlanFixtures.verify(store, verified)
        QAPlanFixtures.add(store, 5, cases: 1, milestone: milestone("R2"))
        let excluded = QAPlanFixtures.add(store, 6, cases: 1, milestone: r1)

        store.addQAMilestonePlan(r1)
        let plan = store.qaMilestonePlans[0]
        XCTAssertEqual(store.qaMilestoneProgress(for: plan).total, 5)

        store.excludeFromQAMilestonePlan(plan.id, ticketID: excluded.id)
        let progress = store.qaMilestoneProgress(for: store.qaMilestonePlans[0])
        XCTAssertEqual(progress.total, 4)
        XCTAssertEqual(progress.verified, 1)
        XCTAssertEqual(progress.count(.failed), 1)
        XCTAssertEqual(progress.count(.testing), 1)
        XCTAssertEqual(progress.count(.ready), 1)
        XCTAssertEqual(progress.remainingMinutes, 50)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(store.qaExcludedTickets(for: store.qaMilestonePlans[0]).map(\.id), [excluded.id])
    }

    func testPlanWithNoMatchingTicketsIsEmpty() {
        let (store, _) = QAPlanFixtures.makeStore()
        store.addQAMilestonePlan(milestone("Gone"))
        let progress = store.qaMilestoneProgress(for: store.qaMilestonePlans[0])
        XCTAssertEqual(progress.total, 0)
        XCTAssertEqual(progress.fraction, 0)
    }

    func testOverdueNeedsAPassedTargetAndUnverifiedTickets() {
        let ticket = Ticket(title: "t")
        let ready = QAPlanCandidate(ticket: ticket, state: .ready, estimateMinutes: 10)
        let done = QAPlanCandidate(ticket: ticket, state: .verified, estimateMinutes: 10)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!

        func progress(_ target: Date?, _ tickets: [QAPlanCandidate]) -> QAMilestoneProgress {
            QAMilestoneProgress(plan: QAMilestonePlan(milestone: "R", targetDate: target), tickets: tickets)
        }
        XCTAssertTrue(progress(yesterday, [ready]).isOverdue(at: now))
        XCTAssertFalse(progress(yesterday, [done]).isOverdue(at: now))
        XCTAssertFalse(progress(now, [ready]).isOverdue(at: now))
        XCTAssertFalse(progress(nil, [ready]).isOverdue(at: now))
        XCTAssertEqual(progress(tomorrow, [ready]).daysRemaining(at: now), 1)
        XCTAssertEqual(progress(yesterday, [ready]).daysRemaining(at: now), -1)
        XCTAssertNil(progress(nil, [ready]).daysRemaining(at: now))
    }

    func testPlanningAMilestoneTicketUpdatesTodaysPlan() {
        let (store, _) = QAPlanFixtures.makeStore()
        let ticket = QAPlanFixtures.add(store, 1, milestone: milestone("R1"))
        let day = Date()

        store.toggleQAPlanned(ticket.id, on: day)
        XCTAssertEqual(store.qaPlan(for: day)?.ticketIDs, [ticket.id])
        store.toggleQAPlanned(ticket.id, on: day)
        XCTAssertEqual(store.qaPlan(for: day)?.ticketIDs, [])
    }
}
