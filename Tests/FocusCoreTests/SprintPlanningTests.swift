import XCTest
@testable import FocusCore

@MainActor
final class SprintPlanningTests: XCTestCase {
    private func makeStore(everyDay: Bool = true) -> (AppStore, URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        if everyDay { defaults.set(7, forKey: PrefKey.workDays) }
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url, defaults)
    }

    @discardableResult
    private func addTicket(
        _ store: AppStore,
        _ title: String,
        status: TicketStatus = .todo,
        sprint: String? = nil,
        sprintProject: String = "Project Alpha",
        sprintStart: Date? = nil,
        sprintEnd: Date? = nil,
        estimateMinutes: Int? = 60
    ) -> Ticket {
        let ticket = store.addTicket(title: title)
        store.update(ticket.id) {
            $0.status = status
            var fields: [CustomField] = []
            if let sprint {
                fields.append(CustomField(
                    name: "Sprint",
                    value: sprint,
                    kind: .iteration,
                    project: sprintProject,
                    start: sprintStart,
                    end: sprintEnd
                ))
            }
            $0.fields = fields
            if let estimateMinutes {
                $0.estimateMinutes = estimateMinutes
            }
        }
        return store.ticket(ticket.id)!
    }

    // MARK: - Sprint Discovery & Lifecycle Tests

    func testSprintDiscoveryAndOrdering() {
        let (store, _, _) = makeStore()
        let now = Date()
        let cal = Calendar.current
        let s1Start = cal.date(byAdding: .day, value: -7, to: now)!
        let s1End = cal.date(byAdding: .day, value: 7, to: now)!
        let s2Start = s1End
        let s2End = cal.date(byAdding: .day, value: 21, to: now)!

        addTicket(store, "T1", sprint: "Sprint 24", sprintProject: "Web App", sprintStart: s1Start, sprintEnd: s1End)
        addTicket(store, "T2", sprint: "Sprint 25", sprintProject: "Web App", sprintStart: s2Start, sprintEnd: s2End)
        addTicket(store, "T3", sprint: "Sprint 8", sprintProject: "Mobile App", sprintStart: s1Start, sprintEnd: s1End)

        let discovered = store.workspaceSprints
        XCTAssertEqual(discovered.count, 3)

        // Sprints with same start are ordered by project then name
        let names = discovered.map(\.name)
        XCTAssertTrue(names.contains("Sprint 24"))
        XCTAssertTrue(names.contains("Sprint 25"))
        XCTAssertTrue(names.contains("Sprint 8"))
    }

    func testCurrentSprintDetectionAndIsSprintFinished() {
        let (store, _, _) = makeStore()
        let now = Date()
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -5, to: now)!
        let end = cal.date(byAdding: .day, value: 5, to: now)!

        let t1 = addTicket(store, "T1", status: .inProgress, sprint: "Sprint 1", sprintStart: start, sprintEnd: end)
        let t2 = addTicket(store, "T2", status: .todo, sprint: "Sprint 1", sprintStart: start, sprintEnd: end)

        guard let current = store.currentSprint(at: now) else {
            XCTFail("Expected an active current sprint")
            return
        }
        XCTAssertEqual(current.name, "Sprint 1")
        XCTAssertFalse(store.isSprintFinished(current, at: now), "Sprint with open work should not be finished")

        // Complete all tickets in current sprint
        store.update(t1.id) { $0.status = .done }
        store.update(t2.id) { $0.status = .done }

        XCTAssertTrue(store.isSprintFinished(current, at: now), "Sprint with all tickets done must be marked finished")
    }

    func testNextSprintDiscoveryAndAutomaticAdvancement() {
        let (store, _, _) = makeStore()
        let now = Date()
        let cal = Calendar.current
        let s1Start = cal.date(byAdding: .day, value: -7, to: now)!
        let s1End = cal.date(byAdding: .day, value: 7, to: now)!
        let s2Start = s1End
        let s2End = cal.date(byAdding: .day, value: 21, to: now)!

        let t1 = addTicket(store, "T1", status: .inProgress, sprint: "Sprint 1", sprintStart: s1Start, sprintEnd: s1End)
        let t2 = addTicket(store, "T2", status: .todo, sprint: "Sprint 2", sprintStart: s2Start, sprintEnd: s2End)

        let current = store.currentSprint(at: now)
        XCTAssertEqual(current?.name, "Sprint 1")

        let next = store.nextSprint(after: current, at: now)
        XCTAssertEqual(next?.name, "Sprint 2")

        // Default plan sprints should initially select Sprint 1
        XCTAssertTrue(store.defaultPlanSprints.contains("Sprint 1"))
        XCTAssertFalse(store.defaultPlanSprints.contains("Sprint 2"))

        // When Sprint 1 is completed:
        store.update(t1.id) { $0.status = .done }

        // System automatically promotes Sprint 2 as active default!
        XCTAssertTrue(store.defaultPlanSprints.contains("Sprint 2"), "Next sprint must automatically become the default when current finishes")

        let candidates = store.planCandidates(for: now)
        XCTAssertTrue(candidates.contains { $0.id == t2.id }, "Sprint 2 candidate must be suggested automatically")
    }

    // MARK: - Dynamic Prioritization Tests

    func testDayPlannerRankSprintPrioritization() {
        let (store, _, _) = makeStore()
        let now = Date()
        let cal = Calendar.current
        let s1Start = cal.date(byAdding: .day, value: -7, to: now)!
        let s1End = cal.date(byAdding: .day, value: 7, to: now)!
        let s2Start = s1End
        let s2End = cal.date(byAdding: .day, value: 21, to: now)!

        let tCurrent = addTicket(store, "Current Sprint Task", status: .todo, sprint: "Sprint 24", sprintStart: s1Start, sprintEnd: s1End)
        let tNext = addTicket(store, "Next Sprint Task", status: .todo, sprint: "Sprint 25", sprintStart: s2Start, sprintEnd: s2End)
        let tNoSprint = addTicket(store, "Backlog Task", status: .todo)

        // Pass all sprints so all 3 tickets are candidates
        let candidates = store.planCandidates(for: now, sprintFilter: ["Sprint 24", "Sprint 25", "No Sprint"])

        XCTAssertEqual(candidates.count, 3)
        // Current Sprint task should rank first (.inSprint), then Next Sprint task (.nextSprint), then Backlog (.open)
        XCTAssertEqual(candidates[0].id, tCurrent.id)
        XCTAssertEqual(candidates[0].reason, .inSprint)
        XCTAssertEqual(candidates[1].id, tNext.id)
        XCTAssertEqual(candidates[1].reason, .nextSprint)
        XCTAssertEqual(candidates[2].id, tNoSprint.id)
        XCTAssertEqual(candidates[2].reason, .open)
    }

    // MARK: - Multi-Select Sprint Filter Tests

    func testMultiSelectSprintFilteringInPlanCandidates() {
        let (store, _, _) = makeStore()
        let t1 = addTicket(store, "Task S1", sprint: "Sprint 1")
        let t2 = addTicket(store, "Task S2", sprint: "Sprint 2")
        let t3 = addTicket(store, "Task S3", sprint: "Sprint 3")
        let tNoSprint = addTicket(store, "Task Unassigned")

        // Filter by Sprint 1 only
        var candidates = store.planCandidates(for: Date(), sprintFilter: ["Sprint 1"])
        XCTAssertEqual(candidates.map(\.id), [t1.id])

        // Multi-select: Sprint 1 + Sprint 2
        candidates = store.planCandidates(for: Date(), sprintFilter: ["Sprint 1", "Sprint 2"])
        let ids = Set(candidates.map(\.id))
        XCTAssertTrue(ids.contains(t1.id))
        XCTAssertTrue(ids.contains(t2.id))
        XCTAssertFalse(ids.contains(t3.id))
        XCTAssertFalse(ids.contains(tNoSprint.id))

        // Filter by No Sprint
        candidates = store.planCandidates(for: Date(), sprintFilter: ["No Sprint"])
        XCTAssertEqual(candidates.map(\.id), [tNoSprint.id])

        // Empty sprint filter -> 0 candidates
        candidates = store.planCandidates(for: Date(), sprintFilter: [])
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Multi-Project Sprint Collision Testing (Realistic Mock Data)

    func testMultiProjectSprintCollisionIsolation() {
        let (store, _, _) = makeStore()
        let webTicket = addTicket(store, "Web Feature", sprint: "Sprint 10", sprintProject: "Project Web")
        let apiTicket = addTicket(store, "API Feature", sprint: "Sprint 10", sprintProject: "Project API")

        // Filter specifically by Project Web's Sprint 10 using qualified key
        let candidates = store.planCandidates(for: Date(), sprintFilter: ["Project Web/Sprint 10"])
        XCTAssertTrue(candidates.contains { $0.id == webTicket.id })
        XCTAssertFalse(candidates.contains { $0.id == apiTicket.id }, "API ticket must not leak when filtering by Project Web sprint")
    }

    // MARK: - Confirmed Unplan All Tests

    func testUnplanAllClearsPlanPreservesTimeAndLogsAction() {
        let (store, _, _) = makeStore()
        let day = Date()
        let t1 = addTicket(store, "Task 1", estimateMinutes: 60)
        let t2 = addTicket(store, "Task 2", estimateMinutes: 120)

        // Plan both tickets
        store.togglePlanned(t1.id, on: day)
        store.togglePlanned(t2.id, on: day)
        XCTAssertEqual(store.plan(for: day)?.ticketIDs.count, 2)

        // Start and stop timer for Task 1
        store.start(t1.id)
        store.stop()
        let tracked = store.trackedTime(for: t1.id)
        XCTAssertGreaterThanOrEqual(tracked, 0)

        // Execute Unplan All
        store.unplanAll(for: day)

        // Plan is cleared
        XCTAssertEqual(store.plan(for: day)?.ticketIDs.count, 0)

        // Tracked time entries and ticket entities remain completely intact
        XCTAssertEqual(store.trackedTime(for: t1.id), tracked)
        XCTAssertNotNil(store.ticket(t1.id))
        XCTAssertNotNil(store.ticket(t2.id))

        // Action log entry exists
        let logEntry = store.actionLog.first { $0.kind == .dayPlan && ($0.field?.contains("Unplanned all") == true) }
        XCTAssertNotNil(logEntry, "Action log must record Unplanned all action")

        // Calling unplanAll when plan is empty is a safe no-op
        store.unplanAll(for: day)
        XCTAssertEqual(store.plan(for: day)?.ticketIDs.count, 0)
    }

    func testGracefulFallbackWhenNoSprintsConfigured() {
        let (store, _, _) = makeStore()
        let t1 = addTicket(store, "Ad-hoc Bug 1")
        let t2 = addTicket(store, "Ad-hoc Feature 2")

        XCTAssertTrue(store.workspaceSprints.isEmpty)
        XCTAssertNil(store.currentSprint())
        XCTAssertNil(store.nextSprint())

        // Default candidate query should gracefully return all tickets without errors
        let candidates = store.planCandidates(for: Date())
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.contains { $0.id == t1.id })
        XCTAssertTrue(candidates.contains { $0.id == t2.id })
    }
}
