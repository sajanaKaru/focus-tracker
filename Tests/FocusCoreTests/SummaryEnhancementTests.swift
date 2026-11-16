import XCTest
@testable import FocusCore

@MainActor
final class SummaryEnhancementTests: XCTestCase {
    private func makeStore() -> (AppStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        return (AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil }), url)
    }

    func testActivityKindPropertiesAndCodable() throws {
        // Verify titles
        XCTAssertEqual(Activity.Kind.codeReview.title, "Code Review")
        XCTAssertEqual(Activity.Kind.support.title, "Customer Support")
        XCTAssertEqual(Activity.Kind.meeting.title, "Meeting")
        XCTAssertEqual(Activity.Kind.call.title, "Call")
        XCTAssertEqual(Activity.Kind.other.title, "Other")

        // Verify SF Symbols
        XCTAssertEqual(Activity.Kind.codeReview.symbol, "doc.text.magnifyingglass")
        XCTAssertEqual(Activity.Kind.support.symbol, "headphones")

        // Codable roundtrip
        for kind in Activity.Kind.allCases {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(Activity.Kind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }

        // Backwards compatibility with raw JSON strings
        let jsonStr = #"["call","meeting","codeReview","support","other"]"#
        let decodedArray = try JSONDecoder().decode([Activity.Kind].self, from: Data(jsonStr.utf8))
        XCTAssertEqual(decodedArray, [.call, .meeting, .codeReview, .support, .other])
    }

    func testDaySummarySectionsCategorization() {
        let (store, _) = makeStore()
        let now = Date()

        // Add activities of various kinds (duration >= 60 seconds)
        store.addActivity(kind: .codeReview, title: "PR #101 Refactor auth", start: now.addingTimeInterval(-1800), end: now)
        store.addActivity(kind: .support, title: "Investigate customer ticket", start: now.addingTimeInterval(-2400), end: now)
        store.addActivity(kind: .meeting, title: "Sprint Planning", start: now.addingTimeInterval(-3600), end: now)
        store.addActivity(kind: .call, title: "Quick Huddle", start: now.addingTimeInterval(-600), end: now)
        store.addActivity(kind: .other, title: "Documentation cleanup", start: now.addingTimeInterval(-1200), end: now)

        let sections = store.daySummarySections(for: now)
        let sectionTitles = sections.map(\.title)

        XCTAssertTrue(sectionTitles.contains("Code Reviews"), "Expected 'Code Reviews' section")
        XCTAssertTrue(sectionTitles.contains("Customer Support"), "Expected 'Customer Support' section")
        XCTAssertTrue(sectionTitles.contains("Meetings & Calls"), "Expected 'Meetings & Calls' section")
        XCTAssertTrue(sectionTitles.contains("Other Activities"), "Expected 'Other Activities' section")

        // Verify items under Meetings & Calls
        if let mcSection = sections.first(where: { $0.title == "Meetings & Calls" }) {
            XCTAssertEqual(mcSection.items.count, 2)
            XCTAssertTrue(mcSection.items.contains { $0.text.contains("Sprint Planning") })
            XCTAssertTrue(mcSection.items.contains { $0.text.contains("Quick Huddle") })
        }

        // Verify items under Code Reviews
        if let crSection = sections.first(where: { $0.title == "Code Reviews" }) {
            XCTAssertEqual(crSection.items.count, 1)
            XCTAssertTrue(crSection.items[0].text.contains("PR #101 Refactor auth"))
            XCTAssertTrue(crSection.items[0].text.contains("30m"))
        }

        // Verify items under Customer Support
        if let csSection = sections.first(where: { $0.title == "Customer Support" }) {
            XCTAssertEqual(csSection.items.count, 1)
            XCTAssertTrue(csSection.items[0].text.contains("Investigate customer ticket"))
            XCTAssertTrue(csSection.items[0].text.contains("40m"))
        }
    }

    func testDaySummaryTextFormatting() {
        let (store, _) = makeStore()
        let now = Date()

        let ticket = store.addTicket(title: "Feature X")
        store.addManualEntry(ticketID: ticket.id, duration: 1800, endingAt: now)
        store.addNote(ticketID: ticket.id, text: "Subtask 1 done")
        store.addNote(ticketID: ticket.id, text: "Subtask 2 in progress")

        store.addActivity(kind: .codeReview, title: "Review PR #42", start: now.addingTimeInterval(-1200), end: now)

        let summaryText = store.daySummaryText(for: now, includeDate: true, includeTomorrow: false)

        // Verify date heading
        XCTAssertTrue(summaryText.contains("========================="))

        // Verify bullet points
        XCTAssertTrue(summaryText.contains("• Feature X") || summaryText.contains("• Local"))
        XCTAssertTrue(summaryText.contains("  - Subtask 1 done"))
        XCTAssertTrue(summaryText.contains("  - Subtask 2 in progress"))

        // Verify Code Reviews section
        XCTAssertTrue(summaryText.contains("Code Reviews"))
        XCTAssertTrue(summaryText.contains("• Review PR #42 (20m)"))

        // Verify clean double-newline spacing between sections
        XCTAssertTrue(summaryText.contains("\n\nCode Reviews"))
    }

    func testDaySummaryHTMLFormatting() {
        let (store, _) = makeStore()
        let now = Date()

        let ticket = store.addTicket(title: "Security <Audit> & Test")
        store.addManualEntry(ticketID: ticket.id, duration: 1200, endingAt: now)
        store.addNote(ticketID: ticket.id, text: "Fixed <script> vulnerability")

        let html = store.daySummaryHTML(for: now, includeDate: true, includeTomorrow: false)

        // Verify semantic tags
        XCTAssertTrue(html.contains("<ul"))
        XCTAssertTrue(html.contains("<li"))
        XCTAssertTrue(html.contains("<p style=\"font-weight: bold;"))

        // Verify escaping
        XCTAssertTrue(html.contains("&lt;Audit&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
    }
}
