import XCTest
@testable import FocusCore

@MainActor
final class PlanProjectStatusTests: XCTestCase {
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
        projectStatus: String? = nil,
        project: String = "Proj1",
        color: String? = nil
    ) -> Ticket {
        let ticket = store.addTicket(title: title)
        store.update(ticket.id) {
            $0.status = status
            if let projectStatus {
                let field = CustomField(name: "Status", value: projectStatus, kind: .select, project: project, color: color)
                $0.fields = [field]
            }
        }
        return store.ticket(ticket.id)!
    }

    // MARK: - Model & Discovery Tests

    func testProjectStatusOptionProperties() {
        let opt = ProjectStatusOption(name: "In Dev", status: .inProgress, color: "blue")
        XCTAssertEqual(opt.id, "In Dev")
        XCTAssertEqual(opt.name, "In Dev")
        XCTAssertEqual(opt.status, .inProgress)
        XCTAssertEqual(opt.color, "blue")
    }

    func testWorkspaceProjectStatusesFallback() {
        let (store, _, _) = makeStore()
        let discovered = store.workspaceProjectStatuses
        XCTAssertEqual(discovered.count, TicketStatus.allCases.count)
        XCTAssertEqual(discovered.map(\.name), TicketStatus.allCases.map(\.title))
    }

    func testWorkspaceProjectStatusesDiscoveryFromRemoteAndTickets() {
        let (store, _, _) = makeStore()
        var options = RemoteOptions()
        options.projectStatus["Project Alpha"] = [
            FieldOption(name: "Ready for Dev", color: "blue"),
            FieldOption(name: "In Dev", color: "purple"),
            FieldOption(name: "Code Review", color: "orange")
        ]
        store.storeOptions(options)

        // Ticket in Project Alpha
        addTicket(store, "T1", status: .todo, projectStatus: "Ready for Dev", project: "Project Alpha")
        // Ticket in Project Beta with its own custom status
        addTicket(store, "T2", status: .testing, projectStatus: "Testing / QA", project: "Project Beta", color: "yellow")

        let discovered = store.workspaceProjectStatuses
        let names = discovered.map(\.name)
        XCTAssertTrue(names.contains("Ready for Dev"))
        XCTAssertTrue(names.contains("In Dev"))
        XCTAssertTrue(names.contains("Code Review"))
        XCTAssertTrue(names.contains("Testing / QA"))

        let readyOpt = discovered.first { $0.name == "Ready for Dev" }
        XCTAssertEqual(readyOpt?.status, .todo)
        XCTAssertEqual(readyOpt?.color, "blue")

        let inDevOpt = discovered.first { $0.name == "In Dev" }
        XCTAssertEqual(inDevOpt?.status, .inProgress)

        let qaOpt = discovered.first { $0.name == "Testing / QA" }
        XCTAssertEqual(qaOpt?.status, .testing)
        XCTAssertEqual(qaOpt?.color, "yellow")
    }

    func testStatusNameResolution() {
        let (store, _, _) = makeStore()
        let standard = addTicket(store, "Standard Ticket", status: .inReview)
        XCTAssertEqual(store.statusName(for: standard), "In Review")

        let custom = addTicket(store, "Custom Ticket", status: .todo, projectStatus: "Ready for Dev")
        XCTAssertEqual(store.statusName(for: custom), "Ready for Dev")
    }

    // MARK: - PlanSettings Serialization Tests

    func testPlanSettingsSerializationRoundTrip() throws {
        let original = PlanSettings(
            workingMinutes: 420,
            focusFactor: 0.8,
            defaultEstimateMinutes: 45,
            workDays: 5,
            includedTicketTypes: ["Bug"],
            includedProjectStatuses: ["In Dev", "Ready for Dev"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlanSettings.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.includedProjectStatuses, ["In Dev", "Ready for Dev"])
    }

    func testPlanSettingsBackwardCompatibilityMissingStatusKey() throws {
        let legacyJSON = """
        {
            "workingMinutes": 480,
            "focusFactor": 0.75,
            "defaultEstimateMinutes": 60,
            "workDays": 5,
            "includedTicketTypes": ["Feature", "Bug"]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PlanSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.includedProjectStatuses, [])
    }

    // MARK: - Candidate Filtering Tests

    func testCandidateFilteringDefaultsToAllNonDone() {
        let (store, _, _) = makeStore()
        let todo = addTicket(store, "Todo Ticket", status: .todo)
        let inProg = addTicket(store, "In Progress Ticket", status: .inProgress)
        let review = addTicket(store, "In Review Ticket", status: .inReview)
        let testing = addTicket(store, "Testing Ticket", status: .testing)
        let done = addTicket(store, "Done Ticket", status: .done)

        let candidateIDs = Set(store.planCandidates(for: Date()).map(\.id))
        XCTAssertTrue(candidateIDs.contains(todo.id))
        XCTAssertTrue(candidateIDs.contains(inProg.id))
        XCTAssertTrue(candidateIDs.contains(review.id))
        XCTAssertTrue(candidateIDs.contains(testing.id))
        // Done tickets are omitted by default
        XCTAssertFalse(candidateIDs.contains(done.id))
    }

    func testCandidateFilteringSettingsExclusion() {
        let (store, _, _) = makeStore()
        let todo = addTicket(store, "Todo Ticket", status: .todo)
        let inProg = addTicket(store, "In Progress Ticket", status: .inProgress)

        var candidates = store.planCandidates(for: Date())
        XCTAssertTrue(candidates.contains { $0.id == todo.id })
        XCTAssertTrue(candidates.contains { $0.id == inProg.id })

        // Exclude Todo status
        store.setIncludedProjectStatus("Todo", isIncluded: false)
        XCTAssertFalse(store.planIncludedProjectStatuses.contains("Todo"))

        candidates = store.planCandidates(for: Date())
        XCTAssertFalse(candidates.contains { $0.id == todo.id })
        XCTAssertTrue(candidates.contains { $0.id == inProg.id })

        // Re-include Todo status
        store.setIncludedProjectStatus("Todo", isIncluded: true)
        XCTAssertTrue(store.planIncludedProjectStatuses.contains("Todo"))

        candidates = store.planCandidates(for: Date())
        XCTAssertTrue(candidates.contains { $0.id == todo.id })
    }

    func testCandidateFilteringCaseInsensitive() {
        let (store, _, _) = makeStore()
        let custom = addTicket(store, "Lower Ticket", projectStatus: "ready for dev")

        // Filter with uppercase
        store.setIncludedProjectStatuses(["READY FOR DEV"])
        let candidates = store.planCandidates(for: Date())
        XCTAssertTrue(candidates.contains { $0.id == custom.id })
    }

    func testCandidateFilteringTransientStatusFilter() {
        let (store, _, _) = makeStore()
        let todo = addTicket(store, "Todo 1", status: .todo)
        let inProg = addTicket(store, "Progress 1", status: .inProgress)

        let filtered = store.planCandidates(for: Date(), statusFilter: ["In Progress"])
        XCTAssertFalse(filtered.contains { $0.id == todo.id })
        XCTAssertTrue(filtered.contains { $0.id == inProg.id })

        // Verify global settings remain intact
        XCTAssertEqual(store.planIncludedProjectStatuses, [])
        let standard = store.planCandidates(for: Date())
        XCTAssertTrue(standard.contains { $0.id == todo.id })
        XCTAssertTrue(standard.contains { $0.id == inProg.id })
    }

    func testEmptyStateWhenAllStatusesDeselected() {
        let (store, _, _) = makeStore()
        _ = addTicket(store, "Todo 1", status: .todo)

        // Empty transient filter
        let emptyCandidates = store.planCandidates(for: Date(), statusFilter: [])
        XCTAssertTrue(emptyCandidates.isEmpty)
    }

    func testSelectAllActiveAndResetToDefaults() {
        let (store, _, _) = makeStore()
        _ = addTicket(store, "Todo 1", status: .todo)

        store.selectAllActiveProjectStatuses()
        XCTAssertFalse(store.planIncludedProjectStatuses.isEmpty)
        XCTAssertFalse(store.planIncludedProjectStatuses.contains("Done"))

        store.resetIncludedProjectStatusesToDefaults()
        XCTAssertTrue(store.planIncludedProjectStatuses.isEmpty)
    }

    func testPersistenceAcrossRestarts() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set(7, forKey: PrefKey.workDays)

        let store1 = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        let todo = addTicket(store1, "Todo 1", status: .todo)
        let inProg = addTicket(store1, "Progress 1", status: .inProgress)

        store1.setIncludedProjectStatus("In Progress", isIncluded: false)

        // App restart simulation
        let store2 = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        XCTAssertFalse(store2.planIncludedProjectStatuses.contains("In Progress"))

        let candidates = store2.planCandidates(for: Date())
        XCTAssertTrue(candidates.contains { $0.id == todo.id })
        XCTAssertFalse(candidates.contains { $0.id == inProg.id })
    }
}
