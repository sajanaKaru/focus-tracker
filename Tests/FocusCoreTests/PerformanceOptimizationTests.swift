import XCTest
@testable import FocusCore

@MainActor
final class PerformanceOptimizationTests: XCTestCase {
    private func makeStore() -> (AppStore, URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-perf-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-perf-\(UUID().uuidString)")!
        defaults.set(7, forKey: PrefKey.workDays)
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url, defaults)
    }

    func testTicketMutationVersionIncrementsOnTicketMutations() {
        let (store, _, _) = makeStore()
        let initialTicketVersion = store.ticketMutationVersion

        // 1. Add ticket
        let ticket = store.addTicket(title: "Task 1", priority: .high)
        XCTAssertGreaterThan(store.ticketMutationVersion, initialTicketVersion)
        let v1 = store.ticketMutationVersion

        // 2. Update ticket
        store.update(ticket.id) { $0.estimateMinutes = 120 }
        XCTAssertGreaterThan(store.ticketMutationVersion, v1)
        let v2 = store.ticketMutationVersion

        // 3. Set included ticket types
        store.setIncludedTicketTypes(["Bug"])
        XCTAssertGreaterThan(store.ticketMutationVersion, v2)
        let v3 = store.ticketMutationVersion

        // 4. Set included project statuses
        store.setIncludedProjectStatuses(["General/Todo"])
        XCTAssertGreaterThan(store.ticketMutationVersion, v3)
        let v4 = store.ticketMutationVersion

        // 5. Delete ticket
        let initialEntryVersion = store.entryMutationVersion
        store.deleteTicket(ticket.id)
        XCTAssertGreaterThan(store.ticketMutationVersion, v4)
        XCTAssertGreaterThan(store.entryMutationVersion, initialEntryVersion)
    }

    func testEntryMutationVersionIncrementsOnEntryMutations() {
        let (store, _, _) = makeStore()
        let ticket = store.addTicket(title: "Task with Entries", priority: .medium)

        let initialEntryVersion = store.entryMutationVersion

        // 1. Add manual entry
        store.addManualEntry(ticketID: ticket.id, duration: 1800)
        XCTAssertGreaterThan(store.entryMutationVersion, initialEntryVersion)
        let v1 = store.entryMutationVersion

        guard let entry = store.entries.first(where: { $0.ticketID == ticket.id }) else {
            XCTFail("Expected entry to exist")
            return
        }

        // 2. Update entry
        store.updateEntry(entry.id, start: entry.start.addingTimeInterval(-60), end: entry.end)
        XCTAssertGreaterThan(store.entryMutationVersion, v1)
        let v2 = store.entryMutationVersion

        // 3. Delete entry
        store.deleteEntry(entry.id)
        XCTAssertGreaterThan(store.entryMutationVersion, v2)
    }

    func testWorkspaceProjectStatusesMemoization() {
        let (store, _, _) = makeStore()
        let ticket = store.addTicket(title: "Status Test")
        store.update(ticket.id) {
            $0.fields = [
                CustomField(name: "Status", value: "In Review", kind: .select, project: "Core")
            ]
        }

        // First read computes and caches
        let firstRead = store.workspaceProjectStatusesByProject
        XCTAssertFalse(firstRead.isEmpty)

        // Second read without mutations should match and reuse cache
        let secondRead = store.workspaceProjectStatusesByProject
        XCTAssertEqual(firstRead.count, secondRead.count)
        XCTAssertEqual(firstRead.first?.project, secondRead.first?.project)

        // Mutating a ticket bumps ticketMutationVersion and updates cache
        store.update(ticket.id) {
            $0.fields = [
                CustomField(name: "Status", value: "QA Ready", kind: .select, project: "Core")
            ]
        }
        let thirdRead = store.workspaceProjectStatusesByProject
        let statuses = thirdRead.first?.statuses.map(\.name) ?? []
        XCTAssertTrue(statuses.contains("QA Ready"))
    }

    func testWorkspaceSprintsMemoization() {
        let (store, _, _) = makeStore()
        let ticket = store.addTicket(title: "Sprint Ticket")
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let end = Calendar.current.date(byAdding: .day, value: 5, to: now)!

        store.update(ticket.id) {
            $0.fields = [
                CustomField(name: "Sprint", value: "Sprint 42", kind: .iteration, project: "Core", start: start, end: end)
            ]
        }

        let firstSprints = store.workspaceSprints
        XCTAssertEqual(firstSprints.count, 1)
        XCTAssertEqual(firstSprints.first?.name, "Sprint 42")

        // Second call reuses cached sprints
        let secondSprints = store.workspaceSprints
        XCTAssertEqual(firstSprints, secondSprints)

        // Mutating ticket updates cached sprints
        store.update(ticket.id) {
            $0.fields = [
                CustomField(name: "Sprint", value: "Sprint 43", kind: .iteration, project: "Core", start: start, end: end)
            ]
        }
        let thirdSprints = store.workspaceSprints
        XCTAssertEqual(thirdSprints.first?.name, "Sprint 43")
    }

    func testTrackedMinutesByTicketIDMemoization() {
        let (store, _, _) = makeStore()
        let ticket = store.addTicket(title: "Time Tracker Ticket")

        store.addManualEntry(ticketID: ticket.id, duration: 1800) // 30 mins
        store.addManualEntry(ticketID: ticket.id, duration: 900)  // 15 mins

        let firstTracked = store.trackedMinutesByTicketID()
        XCTAssertEqual(firstTracked[ticket.id], 45)

        // Second call returns cached dictionary
        let secondTracked = store.trackedMinutesByTicketID()
        XCTAssertEqual(firstTracked, secondTracked)

        // Adding another entry invalidates and updates
        store.addManualEntry(ticketID: ticket.id, duration: 900)  // +15 mins -> 60 mins
        let thirdTracked = store.trackedMinutesByTicketID()
        XCTAssertEqual(thirdTracked[ticket.id], 60)
    }

    func testPlanCandidatesMemoizationAndInvalidation() {
        let (store, _, _) = makeStore()
        let ticket = store.addTicket(title: "Candidate Ticket", priority: .high)
        store.update(ticket.id) { $0.estimateMinutes = 60 }

        let today = Date()
        let firstCandidates = store.planCandidates(for: today)
        XCTAssertEqual(firstCandidates.count, 1)
        XCTAssertEqual(firstCandidates.first?.id, ticket.id)

        // Subsequent call with same parameters hits memoized cache
        let secondCandidates = store.planCandidates(for: today)
        XCTAssertEqual(firstCandidates, secondCandidates)

        // Mutating ticket invalidates candidates cache
        store.update(ticket.id) { $0.estimateMinutes = 120 }
        let thirdCandidates = store.planCandidates(for: today)
        XCTAssertEqual(thirdCandidates.first?.estimateMinutes, 120)

        // Plan mutation (e.g. togglePlanned) also updates version and invalidates
        let planVersionBefore = store.planMutationVersion
        store.togglePlanned(ticket.id, on: today)
        XCTAssertGreaterThan(store.planMutationVersion, planVersionBefore)

        let fourthCandidates = store.planCandidates(for: today)
        XCTAssertEqual(fourthCandidates.count, 1)
    }
}
