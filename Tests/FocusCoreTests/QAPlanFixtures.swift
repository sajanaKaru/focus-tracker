import Foundation
@testable import FocusCore

@MainActor
enum QAPlanFixtures {
    static func makeStore(url: URL? = nil) -> (AppStore, URL) {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set(7, forKey: PrefKey.workDays)
        defaults.set(60, forKey: PrefKey.workingMinutes)
        defaults.set(100, forKey: PrefKey.focusPercent)
        let storeURL = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: storeURL, defaults: defaults, transport: RecordingTransport { _ in (200, "{}") }, tokenProvider: { "t" })
        return (store, storeURL)
    }

    static func sprint(_ name: String, start: Date, end: Date) -> CustomField {
        CustomField(name: "Sprint", value: name, kind: .iteration, project: "Board", start: start, end: end)
    }

    /// A ticket deployed to Beta (so it is a QA candidate) with `cases` untested cases.
    @discardableResult
    static func add(_ store: AppStore, _ number: Int, cases: Int = 1, sprints: [CustomField] = [], milestone: Milestone? = nil) -> Ticket {
        let ticket = Ticket(
            title: "T\(number)", status: .testing, milestone: milestone,
            fields: [CustomField(name: "Status", value: "Deployed to Beta", kind: .select, project: "Board")] + sprints,
            github: GitHubRef(repo: "me/a", number: number, url: "https://github.com/me/a/issues/\(number)")
        )
        store.insertTicketForTest(ticket)
        for i in 0..<cases { store.addTestCase(ticketID: ticket.id, title: "case \(i)") }
        return ticket
    }

    static func verify(_ store: AppStore, _ ticket: Ticket) {
        store.testVerdicts.append(TestVerdict(ticketID: ticket.id, environment: .beta, outcome: .pass, summary: "ok", tester: "qa"))
    }

    static func fail(_ store: AppStore, _ ticket: Ticket) {
        store.testVerdicts.append(TestVerdict(ticketID: ticket.id, environment: .beta, outcome: .fail, summary: "bad", tester: "qa"))
    }
}
