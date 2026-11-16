import XCTest
@testable import FocusCore

@MainActor
final class SummaryGroupingTests: XCTestCase {
    private func makeStore() -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url)
    }

    // MARK: - SummaryClassifier Tests

    func testSingleLabelMatching() {
        let bugTicket = Ticket(title: "Crash on launch", labels: ["bug"])
        XCTAssertEqual(SummaryClassifier.category(for: bugTicket, mode: .byType), "Bugs")

        let defectTicket = Ticket(title: "Button misaligned", labels: ["defect"])
        XCTAssertEqual(SummaryClassifier.category(for: defectTicket, mode: .byType), "Bugs")

        let fixTicket = Ticket(title: "Memory leak", labels: ["fix"])
        XCTAssertEqual(SummaryClassifier.category(for: fixTicket, mode: .byType), "Bugs")

        let featTicket = Ticket(title: "Dark mode", labels: ["feature"])
        XCTAssertEqual(SummaryClassifier.category(for: featTicket, mode: .byType), "Features")

        let enhancementTicket = Ticket(title: "Export CSV", labels: ["enhancement"])
        XCTAssertEqual(SummaryClassifier.category(for: enhancementTicket, mode: .byType), "Features")

        let featShortTicket = Ticket(title: "Quick switch", labels: ["feat"])
        XCTAssertEqual(SummaryClassifier.category(for: featShortTicket, mode: .byType), "Features")

        let changeTicket = Ticket(title: "New typography", labels: ["change"])
        XCTAssertEqual(SummaryClassifier.category(for: changeTicket, mode: .byType), "Changes")

        let improvementTicket = Ticket(title: "Better contrast", labels: ["improvement"])
        XCTAssertEqual(SummaryClassifier.category(for: improvementTicket, mode: .byType), "Changes")

        let modTicket = Ticket(title: "Adjust padding", labels: ["mod"])
        XCTAssertEqual(SummaryClassifier.category(for: modTicket, mode: .byType), "Changes")

        let taskTicket = Ticket(title: "Update deps", labels: ["task"])
        XCTAssertEqual(SummaryClassifier.category(for: taskTicket, mode: .byType), "Tasks")

        let choreTicket = Ticket(title: "Clean build scripts", labels: ["chore"])
        XCTAssertEqual(SummaryClassifier.category(for: choreTicket, mode: .byType), "Tasks")

        let refactorTicket = Ticket(title: "Extract parser", labels: ["refactor"])
        XCTAssertEqual(SummaryClassifier.category(for: refactorTicket, mode: .byType), "Tasks")

        let maintenanceTicket = Ticket(title: "Bump swift version", labels: ["maintenance"])
        XCTAssertEqual(SummaryClassifier.category(for: maintenanceTicket, mode: .byType), "Tasks")
    }

    func testPrefixStrippingAndCaseInsensitivity() {
        let typeBug = Ticket(title: "Issue", labels: ["Type: Bug"])
        XCTAssertEqual(SummaryClassifier.category(for: typeBug, mode: .byType), "Bugs")

        let typeSlashFeature = Ticket(title: "Issue", labels: ["type/FEATURE"])
        XCTAssertEqual(SummaryClassifier.category(for: typeSlashFeature, mode: .byType), "Features")

        let kindChange = Ticket(title: "Issue", labels: ["kind: Improvement"])
        XCTAssertEqual(SummaryClassifier.category(for: kindChange, mode: .byType), "Changes")

        let kindSlashTask = Ticket(title: "Issue", labels: ["kind/chore"])
        XCTAssertEqual(SummaryClassifier.category(for: kindSlashTask, mode: .byType), "Tasks")
    }

    func testMultiLabelPrecedence() {
        // Bugs > Features
        let bugAndFeat = Ticket(title: "Buggy feature", labels: ["feature", "bug"])
        XCTAssertEqual(SummaryClassifier.category(for: bugAndFeat, mode: .byType), "Bugs")

        // Bugs > Tasks
        let bugAndChore = Ticket(title: "Cleanup bug", labels: ["chore", "bug", "infra"])
        XCTAssertEqual(SummaryClassifier.category(for: bugAndChore, mode: .byType), "Bugs")

        // Features > Changes
        let featAndChange = Ticket(title: "New setting", labels: ["improvement", "feature"])
        XCTAssertEqual(SummaryClassifier.category(for: featAndChange, mode: .byType), "Features")

        // Changes > Tasks
        let changeAndChore = Ticket(title: "Refactor UI", labels: ["chore", "change"])
        XCTAssertEqual(SummaryClassifier.category(for: changeAndChore, mode: .byType), "Changes")
    }

    func testIssueTypePrecedence() {
        // Explicit issueType matches directly
        let bugType = Ticket(title: "Crash", issueType: IssueType(name: "Bug"))
        XCTAssertEqual(SummaryClassifier.category(for: bugType, mode: .byType), "Bugs")

        let featureType = Ticket(title: "New UX", issueType: IssueType(name: "Feature"))
        XCTAssertEqual(SummaryClassifier.category(for: featureType, mode: .byType), "Features")

        // Bug label overrides non-bug issueType
        let taskWithBugLabel = Ticket(title: "Chore that broke", labels: ["bug"], issueType: IssueType(name: "Task"))
        XCTAssertEqual(SummaryClassifier.category(for: taskWithBugLabel, mode: .byType), "Bugs")

        // Non-bug issueType takes precedence over general/chore labels
        let featureWithChoreLabel = Ticket(title: "Feature with cleanup", labels: ["chore"], issueType: IssueType(name: "Feature"))
        XCTAssertEqual(SummaryClassifier.category(for: featureWithChoreLabel, mode: .byType), "Features")
    }

    func testFallbackToGeneralTasks() {
        let noLabels = Ticket(title: "Mystery item")
        XCTAssertEqual(SummaryClassifier.category(for: noLabels, mode: .byType), "General Tasks")

        let unknownLabels = Ticket(title: "Misc item", labels: ["urgent", "frontend", "p1"])
        XCTAssertEqual(SummaryClassifier.category(for: unknownLabels, mode: .byType), "General Tasks")
    }

    func testStatusModeClassification() {
        let doneTicket = Ticket(title: "Finished work", status: .done, labels: ["bug"])
        XCTAssertEqual(SummaryClassifier.category(for: doneTicket, mode: .byStatus), "Done")

        let inProgTicket = Ticket(title: "Active work", status: .inProgress, labels: ["feature"])
        XCTAssertEqual(SummaryClassifier.category(for: inProgTicket, mode: .byStatus), "In Progress")

        let todoTicket = Ticket(title: "Backlog work", status: .todo, labels: ["bug"])
        XCTAssertEqual(SummaryClassifier.category(for: todoTicket, mode: .byStatus), "Todo")
    }

    // MARK: - AppStore Integration Tests

    func testDaySummarySectionsWithModes() {
        let (store, _) = makeStore()
        let now = Date()

        let bugTicket = store.addTicket(title: "Fix crash on startup")
        store.update(bugTicket.id) {
            $0.labels = ["bug"]
            $0.status = .inProgress
        }
        store.addManualEntry(ticketID: bugTicket.id, duration: 1800, endingAt: now)

        let featTicket = store.addTicket(title: "Add export to JSON")
        store.update(featTicket.id) {
            $0.labels = ["feature"]
            $0.status = .done
        }
        store.addManualEntry(ticketID: featTicket.id, duration: 2400, endingAt: now)

        let taskTicket = store.addTicket(title: "Update dependencies")
        store.update(taskTicket.id) {
            $0.labels = ["chore"]
            $0.status = .inProgress
        }
        store.addManualEntry(ticketID: taskTicket.id, duration: 1200, endingAt: now)

        // Test explicit .byType mode
        let typeSections = store.daySummarySections(for: now, mode: .byType)
        let typeTitles = typeSections.map(\.title)
        XCTAssertTrue(typeTitles.contains("Bugs"), "Expected Bugs section in .byType mode")
        XCTAssertTrue(typeTitles.contains("Features"), "Expected Features section in .byType mode")
        XCTAssertTrue(typeTitles.contains("Tasks"), "Expected Tasks section in .byType mode")
        XCTAssertFalse(typeTitles.contains("Done"))

        // Test explicit .byStatus mode
        let statusSections = store.daySummarySections(for: now, mode: .byStatus)
        let statusTitles = statusSections.map(\.title)
        XCTAssertTrue(statusTitles.contains("Done"), "Expected Done section in .byStatus mode")
        XCTAssertTrue(statusTitles.contains("In Progress"), "Expected In Progress section in .byStatus mode")
        XCTAssertFalse(statusTitles.contains("Bugs"))

        // Test store default mode toggle
        store.summaryGroupingMode = .byStatus
        XCTAssertEqual(store.summaryGroupingMode, .byStatus)
        let defaultStatusSections = store.daySummarySections(for: now)
        XCTAssertTrue(defaultStatusSections.map(\.title).contains("Done"))

        store.summaryGroupingMode = .byType
        XCTAssertEqual(store.summaryGroupingMode, .byType)
        let defaultTypeSections = store.daySummarySections(for: now)
        XCTAssertTrue(defaultTypeSections.map(\.title).contains("Bugs"))
    }

    func testDaySummaryTextAndHTMLGeneration() {
        let (store, _) = makeStore()
        let now = Date()

        let ticket = store.addTicket(title: "Fix payment crash")
        store.update(ticket.id) {
            $0.labels = ["bug"]
            $0.status = .done
        }
        store.addManualEntry(ticketID: ticket.id, duration: 3600, endingAt: now)

        // Text summary
        let textByType = store.daySummaryText(for: now, mode: .byType)
        XCTAssertTrue(textByType.contains("Bugs\n• Fix payment crash"), "Expected Bugs header in text")

        let textByStatus = store.daySummaryText(for: now, mode: .byStatus)
        XCTAssertTrue(textByStatus.contains("Done\n• Fix payment crash"), "Expected Done header in text")

        // HTML summary
        let htmlByType = store.daySummaryHTML(for: now, mode: .byType)
        XCTAssertTrue(htmlByType.contains("Bugs</p>"), "Expected Bugs in HTML")

        let htmlByStatus = store.daySummaryHTML(for: now, mode: .byStatus)
        XCTAssertTrue(htmlByStatus.contains("Done</p>"), "Expected Done in HTML")
    }
}
