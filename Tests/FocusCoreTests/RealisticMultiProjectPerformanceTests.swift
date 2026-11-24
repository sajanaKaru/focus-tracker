import XCTest
@testable import FocusCore

@MainActor
final class RealisticMultiProjectPerformanceTests: XCTestCase {
    private func makeStore() -> (AppStore, URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-realistic-perf-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-realistic-perf-\(UUID().uuidString)")!
        defaults.set(7, forKey: PrefKey.workDays)
        defaults.set(480, forKey: PrefKey.workingMinutes)
        defaults.set(75, forKey: PrefKey.focusPercent)
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url, defaults)
    }

    /// Tests multi-project performance conforming strictly to realistic-mock-data specifications:
    /// 650+ tickets across 3 distinct projects (Web App, Mobile App, API Service)
    /// Overlapping statuses ("In Dev", "Todo", "Code Review", "QA Testing", "Done")
    /// Active Sprints with overlapping and distinct iteration intervals
    /// 120+ time entries across 45 tickets with active timer running
    func testRealisticLargeDatasetMultiProjectPerformanceAndMemoization() {
        let (store, _, _) = makeStore()

        let now = Date()
        let sprint14Start = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        let sprint14End = Calendar.current.date(byAdding: .day, value: 9, to: now)!
        let sprintW46Start = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let sprintW46End = Calendar.current.date(byAdding: .day, value: 5, to: now)!

        var createdTicketIDs: [UUID] = []

        // Project 1: Web App (250 tickets)
        for i in 1...250 {
            let statusName = (i % 5 == 0) ? "In Dev 🏃" : ((i % 5 == 1) ? "Code Review" : ((i % 5 == 2) ? "Done" : "Todo"))
            let statusField = CustomField(name: "Status", value: statusName, kind: .select, project: "Web App")
            let sprintField = CustomField(name: "Sprint", value: "Sprint 14", kind: .iteration, project: "Web App", start: sprint14Start, end: sprint14End)
            let ticket = Ticket(
                title: "Web feature/bug ticket #\(i) with detailed responsive UI interactions",
                status: (statusName.contains("In Dev")) ? .inProgress : ((statusName == "Code Review") ? .inReview : ((statusName == "Done") ? .done : .todo)),
                fields: [statusField, sprintField],
                github: GitHubRef(repo: "org/web-app", number: i, url: "https://github.com/org/web-app/issues/\(i)")
            )
            store.insertTicketForTest(ticket)
            createdTicketIDs.append(ticket.id)
        }

        // Project 2: Mobile App (220 tickets)
        for i in 1...220 {
            let statusName = (i % 4 == 0) ? "🏃 In Dev" : ((i % 4 == 1) ? "Testing" : ((i % 4 == 2) ? "Done" : "Todo"))
            let statusField = CustomField(name: "Status", value: statusName, kind: .select, project: "Mobile App")
            let sprintField = CustomField(name: "Sprint", value: "Sprint 14", kind: .iteration, project: "Mobile App", start: sprint14Start, end: sprint14End)
            let ticket = Ticket(
                title: "Mobile screen optimization ticket #\(i) handling touch and gesture pipelines",
                status: (statusName.contains("In Dev")) ? .inProgress : ((statusName == "Testing") ? .testing : ((statusName == "Done") ? .done : .todo)),
                fields: [statusField, sprintField],
                github: GitHubRef(repo: "org/mobile-app", number: i, url: "https://github.com/org/mobile-app/issues/\(i)")
            )
            store.insertTicketForTest(ticket)
            createdTicketIDs.append(ticket.id)
        }

        // Project 3: API Service (180 tickets)
        for i in 1...180 {
            let statusName = (i % 4 == 0) ? "In Dev" : ((i % 4 == 1) ? "QA Testing" : ((i % 4 == 2) ? "Done" : "Todo"))
            let statusField = CustomField(name: "Status", value: statusName, kind: .select, project: "API Service")
            let sprintField = CustomField(name: "Sprint", value: "Sprint 2026-W46", kind: .iteration, project: "API Service", start: sprintW46Start, end: sprintW46End)
            let ticket = Ticket(
                title: "API endpoint handler ticket #\(i) streaming protobuf payloads efficiently",
                status: (statusName == "In Dev") ? .inProgress : ((statusName == "QA Testing") ? .testing : ((statusName == "Done") ? .done : .todo)),
                fields: [statusField, sprintField],
                github: GitHubRef(repo: "org/api-service", number: i, url: "https://github.com/org/api-service/issues/\(i)")
            )
            store.insertTicketForTest(ticket)
            createdTicketIDs.append(ticket.id)
        }

        XCTAssertEqual(store.tickets.count, 650)

        // Add 120 time entries distributed across 45 tickets
        let sample45TicketIDs = Array(createdTicketIDs.prefix(45))
        for j in 0..<120 {
            let targetTicketID = sample45TicketIDs[j % sample45TicketIDs.count]
            let duration = TimeInterval((j + 1) * 60)
            store.addManualEntry(ticketID: targetTicketID, duration: duration)
        }
        XCTAssertEqual(store.entries.count, 120)

        // Start active tracking timer on the first ticket
        store.start(sample45TicketIDs[0])
        XCTAssertTrue(store.isTracking(sample45TicketIDs[0]))
        XCTAssertNotNil(store.activeEntry)

        // 1. Benchmark: First Uncached Calculation of Plan Candidates
        let startFirst = DispatchTime.now()
        let firstCandidates = store.planCandidates(for: now)
        let endFirst = DispatchTime.now()
        let firstDurationMs = Double(endFirst.uptimeNanoseconds - startFirst.uptimeNanoseconds) / 1_000_000.0
        XCTAssertFalse(firstCandidates.isEmpty)

        // 2. Benchmark: Second Memoized Retrieval (< 5ms requirement)
        let startSecond = DispatchTime.now()
        let secondCandidates = store.planCandidates(for: now)
        let endSecond = DispatchTime.now()
        let secondDurationMs = Double(endSecond.uptimeNanoseconds - startSecond.uptimeNanoseconds) / 1_000_000.0

        XCTAssertEqual(firstCandidates.count, secondCandidates.count)
        XCTAssertLessThan(secondDurationMs, 5.0, "Memoized query must return in under 5ms, took \(secondDurationMs)ms")

        // 3. Verify Active Timer Tick Invalidation Decoupling
        // Verify that updating store.now during timer ticks does NOT bump ticket/entry/plan mutation versions
        let ticketMutationVersionBefore = store.ticketMutationVersion
        let entryMutationVersionBefore = store.entryMutationVersion
        let planMutationVersionBefore = store.planMutationVersion

        // Simulate 2 seconds of timer ticks
        let tickExpectation = expectation(description: "Wait for background timer ticks")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            tickExpectation.fulfill()
        }
        wait(for: [tickExpectation], timeout: 4.0)

        // Versions must remain unchanged
        XCTAssertEqual(store.ticketMutationVersion, ticketMutationVersionBefore)
        XCTAssertEqual(store.entryMutationVersion, entryMutationVersionBefore)
        XCTAssertEqual(store.planMutationVersion, planMutationVersionBefore)

        let startTickCached = DispatchTime.now()
        let candidatesAfterTicks = store.planCandidates(for: now)
        let endTickCached = DispatchTime.now()
        let tickDurationMs = Double(endTickCached.uptimeNanoseconds - startTickCached.uptimeNanoseconds) / 1_000_000.0

        XCTAssertEqual(candidatesAfterTicks.count, firstCandidates.count)
        XCTAssertLessThan(tickDurationMs, 5.0, "Candidate retrieval across timer ticks must hit memoized cache in < 5ms, took \(tickDurationMs)ms")

        // 4. Verify Cross-Project Status Grouping & Sprints Memoization
        let projectStatuses = store.workspaceProjectStatusesByProject
        XCTAssertEqual(projectStatuses.count, 3)
        let projectNames = Set(projectStatuses.map(\.project))
        XCTAssertEqual(projectNames, ["Web App", "Mobile App", "API Service"])

        let sprints = store.workspaceSprints
        // Key is "\(sprint.project)/\(sprint.value)", so each project's sprint is unique
        XCTAssertEqual(sprints.count, 3) // Web App/Sprint 14, Mobile App/Sprint 14, API Service/Sprint 2026-W46

        // 5. Verify Invalidation on Actual Ticket Mutation
        guard let candidateToMutate = firstCandidates.first(where: { ($0.trackedMinutes) == 0 }) else {
            XCTFail("Expected at least one candidate with 0 tracked minutes")
            return
        }
        let targetID = candidateToMutate.id

        store.update(targetID) {
            $0.estimateMinutes = 180
        }
        XCTAssertGreaterThan(store.ticketMutationVersion, ticketMutationVersionBefore)

        let startAfterMutation = DispatchTime.now()
        let candidatesAfterMutation = store.planCandidates(for: now)
        let endAfterMutation = DispatchTime.now()
        _ = Double(endAfterMutation.uptimeNanoseconds - startAfterMutation.uptimeNanoseconds) / 1_000_000.0

        XCTAssertFalse(candidatesAfterMutation.isEmpty)
        let mutatedCandidate = candidatesAfterMutation.first { $0.id == targetID }
        XCTAssertEqual(mutatedCandidate?.estimateMinutes, 180)
    }
}
