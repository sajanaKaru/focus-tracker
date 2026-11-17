import XCTest
@testable import FocusCore

@MainActor
final class PlanTicketTypeTests: XCTestCase {
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
        labels: [String] = [],
        issueType: String? = nil,
        isQuickCapture: Bool = false
    ) -> Ticket {
        let ticket = store.addTicket(title: title)
        store.update(ticket.id) {
            $0.labels = labels
            if let issueType { $0.issueType = IssueType(name: issueType) }
            if isQuickCapture { $0.isQuickCapture = true }
        }
        return store.ticket(ticket.id)!
    }

    // MARK: - Category Metadata Tests

    func testPlanTicketCategoryProperties() {
        XCTAssertEqual(PlanTicketCategory.allCases.count, 5)
        XCTAssertEqual(PlanTicketCategory.feature.rawValue, "Feature")
        XCTAssertEqual(PlanTicketCategory.bug.rawValue, "Bug")
        XCTAssertEqual(PlanTicketCategory.task.rawValue, "Task")
        XCTAssertEqual(PlanTicketCategory.quickCapture.rawValue, "Quick Capture")
        XCTAssertEqual(PlanTicketCategory.other.rawValue, "Other")

        XCTAssertEqual(PlanTicketCategory.feature.iconName, "star.fill")
        XCTAssertEqual(PlanTicketCategory.bug.iconName, "ladybug.fill")
        XCTAssertEqual(PlanTicketCategory.task.iconName, "checkmark.square")
        XCTAssertEqual(PlanTicketCategory.quickCapture.iconName, "bolt.fill")
        XCTAssertEqual(PlanTicketCategory.other.iconName, "tag.fill")
    }

    // MARK: - Classification Logic Tests

    func testTicketClassificationQuickCapture() {
        let ticket = Ticket(
            title: "Quick note",
            labels: ["feature"],
            issueType: IssueType(name: "Bug"),
            isQuickCapture: true
        )
        XCTAssertEqual(ticket.planCategory, PlanTicketCategory.quickCapture)
    }

    func testTicketClassificationIssueType() {
        let bug = Ticket(title: "Fix crash", issueType: IssueType(name: "Bug"))
        XCTAssertEqual(bug.planCategory, PlanTicketCategory.bug)

        let defect = Ticket(title: "UI glitch", issueType: IssueType(name: "Defect"))
        XCTAssertEqual(defect.planCategory, PlanTicketCategory.bug)

        let feature = Ticket(title: "Add export", issueType: IssueType(name: "Feature"))
        XCTAssertEqual(feature.planCategory, PlanTicketCategory.feature)

        let story = Ticket(title: "User login", issueType: IssueType(name: "Story"))
        XCTAssertEqual(story.planCategory, PlanTicketCategory.feature)

        let enhancement = Ticket(title: "Faster sync", issueType: IssueType(name: "Enhancement"))
        XCTAssertEqual(enhancement.planCategory, PlanTicketCategory.feature)

        let task = Ticket(title: "Refactor storage", issueType: IssueType(name: "Task"))
        XCTAssertEqual(task.planCategory, PlanTicketCategory.task)

        let chore = Ticket(title: "Update deps", issueType: IssueType(name: "Chore"))
        XCTAssertEqual(chore.planCategory, PlanTicketCategory.task)
    }

    func testTicketClassificationLabels() {
        let bugLabel = Ticket(title: "Broken button", labels: ["bug"])
        XCTAssertEqual(bugLabel.planCategory, PlanTicketCategory.bug)

        let bugPrefixLabel = Ticket(title: "Broken link", labels: ["bug/p1"])
        XCTAssertEqual(bugPrefixLabel.planCategory, PlanTicketCategory.bug)

        let featLabel = Ticket(title: "New dashboard", labels: ["feature"])
        XCTAssertEqual(featLabel.planCategory, PlanTicketCategory.feature)

        let enhLabel = Ticket(title: "Better logs", labels: ["enhancement"])
        XCTAssertEqual(enhLabel.planCategory, PlanTicketCategory.feature)

        let taskLabel = Ticket(title: "Clean cache", labels: ["task"])
        XCTAssertEqual(taskLabel.planCategory, PlanTicketCategory.task)

        let choreLabel = Ticket(title: "Bump version", labels: ["chore"])
        XCTAssertEqual(choreLabel.planCategory, PlanTicketCategory.task)

        let other = Ticket(title: "Read docs", labels: ["documentation", "internal"])
        XCTAssertEqual(other.planCategory, PlanTicketCategory.other)

        let unlabeled = Ticket(title: "Investigate latency")
        XCTAssertEqual(unlabeled.planCategory, PlanTicketCategory.other)
    }

    func testTicketClassificationPrecedence() {
        // Quick Capture takes precedence over IssueType and Labels
        let qc = Ticket(title: "Draft idea", labels: ["bug"], issueType: IssueType(name: "Task"), isQuickCapture: true)
        XCTAssertEqual(qc.planCategory, PlanTicketCategory.quickCapture)

        // IssueType takes precedence over Labels
        let issueWins = Ticket(title: "Mixed types", labels: ["task"], issueType: IssueType(name: "Bug"))
        XCTAssertEqual(issueWins.planCategory, PlanTicketCategory.bug)
    }

    // MARK: - PlanSettings Serialization Tests

    func testPlanSettingsSerializationRoundTrip() throws {
        let original = PlanSettings(
            workingMinutes: 300,
            focusFactor: 0.8,
            defaultEstimateMinutes: 45,
            workDays: 6,
            includedTicketTypes: [PlanTicketCategory.bug.rawValue, PlanTicketCategory.feature.rawValue]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlanSettings.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.includedTicketTypes, [PlanTicketCategory.bug.rawValue, PlanTicketCategory.feature.rawValue])
    }

    func testPlanSettingsBackwardCompatibilityMissingKey() throws {
        // Older JSON payloads without `includedTicketTypes`
        let legacyJSON = """
        {
            "workingMinutes": 480,
            "focusFactor": 0.75,
            "defaultEstimateMinutes": 60,
            "workDays": 5
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PlanSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.workingMinutes, 480)
        XCTAssertEqual(decoded.focusFactor, 0.75)
        XCTAssertEqual(decoded.workDays, 5)
        XCTAssertEqual(decoded.includedTicketTypes, Set(PlanTicketCategory.allCases.map(\.rawValue)))
    }

    func testPlanSettingsBackwardCompatibilityEmptyKey() throws {
        // JSON payload where `includedTicketTypes` was empty
        let emptyJSON = """
        {
            "workingMinutes": 480,
            "focusFactor": 0.75,
            "defaultEstimateMinutes": 60,
            "workDays": 5,
            "includedTicketTypes": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PlanSettings.self, from: emptyJSON)
        XCTAssertEqual(decoded.includedTicketTypes, Set(PlanTicketCategory.allCases.map(\.rawValue)))
    }

    // MARK: - AppStore Candidate Filtering Tests

    func testAppStoreCandidateFilteringDefaults() {
        let (store, _, _) = makeStore()
        let t1 = addTicket(store, "Feature 1", labels: ["feature"])
        let t2 = addTicket(store, "Bug 1", labels: ["bug"])
        let t3 = addTicket(store, "Task 1", labels: ["task"])
        let t4 = addTicket(store, "QC 1", isQuickCapture: true)
        let t5 = addTicket(store, "Unclassified 1")

        let candidateIDs = Set(store.planCandidates(for: Date()).map(\.id))
        XCTAssertTrue(candidateIDs.contains(t1.id))
        XCTAssertTrue(candidateIDs.contains(t2.id))
        XCTAssertTrue(candidateIDs.contains(t3.id))
        XCTAssertTrue(candidateIDs.contains(t4.id))
        XCTAssertTrue(candidateIDs.contains(t5.id))
    }

    func testAppStoreCandidateFilteringSettingsExclusion() {
        let (store, _, _) = makeStore()
        let bug = addTicket(store, "A bug", labels: ["bug"])
        let feat = addTicket(store, "A feature", labels: ["feature"])

        var candidates = store.planCandidates(for: Date())
        XCTAssertTrue(candidates.contains { $0.id == bug.id })
        XCTAssertTrue(candidates.contains { $0.id == feat.id })

        // Exclude bugs in persistent settings
        store.setIncludedTicketType(.bug, isIncluded: false)
        XCTAssertFalse(store.planIncludedTicketTypes.contains(PlanTicketCategory.bug.rawValue))

        candidates = store.planCandidates(for: Date())
        XCTAssertFalse(candidates.contains { $0.id == bug.id })
        XCTAssertTrue(candidates.contains { $0.id == feat.id })

        // Re-enable bugs
        store.setIncludedTicketType(.bug, isIncluded: true)
        XCTAssertTrue(store.planIncludedTicketTypes.contains(PlanTicketCategory.bug.rawValue))

        candidates = store.planCandidates(for: Date())
        XCTAssertTrue(candidates.contains { $0.id == bug.id })
    }

    func testAppStoreCandidateFilteringTransientTypeFilter() {
        let (store, _, _) = makeStore()
        let bug = addTicket(store, "Fix login", labels: ["bug"])
        let task = addTicket(store, "Update README", labels: ["task"])

        // Transient filter for only bugs without altering global settings
        let bugOnlyFilter: Set<String> = [PlanTicketCategory.bug.rawValue]
        let filteredCandidates = store.planCandidates(for: Date(), typeFilter: bugOnlyFilter)

        XCTAssertTrue(filteredCandidates.contains { $0.id == bug.id })
        XCTAssertFalse(filteredCandidates.contains { $0.id == task.id })

        // Verify global settings are untouched
        XCTAssertEqual(store.planIncludedTicketTypes, Set(PlanTicketCategory.allCases.map(\.rawValue)))
        let standardCandidates = store.planCandidates(for: Date())
        XCTAssertTrue(standardCandidates.contains { $0.id == bug.id })
        XCTAssertTrue(standardCandidates.contains { $0.id == task.id })
    }

    func testAppStoreEmptyStateWhenAllTypesDeselected() {
        let (store, _, _) = makeStore()
        _ = addTicket(store, "Bug 1", labels: ["bug"])
        _ = addTicket(store, "Feature 1", labels: ["feature"])

        // Deselect all types via transient filter
        let emptyCandidates = store.planCandidates(for: Date(), typeFilter: [])
        XCTAssertTrue(emptyCandidates.isEmpty)

        // Deselect all types via global settings
        store.setIncludedTicketTypes([])
        let settingsEmptyCandidates = store.planCandidates(for: Date())
        XCTAssertTrue(settingsEmptyCandidates.isEmpty)
    }

    func testAppStoreSettingsPersistenceAcrossRestarts() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set(7, forKey: PrefKey.workDays)

        let store1 = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        let feat = addTicket(store1, "Feature 1", labels: ["feature"])
        let bug = addTicket(store1, "Bug 1", labels: ["bug"])

        // Turn off Feature
        store1.setIncludedTicketType(.feature, isIncluded: false)
        XCTAssertFalse(store1.planIncludedTicketTypes.contains(PlanTicketCategory.feature.rawValue))

        // Create new store instance with the same UserDefaults (simulating app restart)
        let store2 = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        XCTAssertFalse(store2.planIncludedTicketTypes.contains(PlanTicketCategory.feature.rawValue))

        let candidates = store2.planCandidates(for: Date())
        XCTAssertFalse(candidates.contains { $0.id == feat.id })
        XCTAssertTrue(candidates.contains { $0.id == bug.id })
    }
}
