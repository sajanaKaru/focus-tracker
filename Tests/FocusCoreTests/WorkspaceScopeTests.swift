import XCTest
@testable import FocusCore

@MainActor
final class WorkspaceScopeTests: XCTestCase {
    private func makeStore() -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        let store = AppStore(storeURL: url, defaults: defaults, tokenProvider: { nil })
        store.setGitHubLogin("me")
        return store
    }

    func testTimeFollowsSelectedWorkspace() {
        let store = makeStore()
        let acme = store.addTicket(title: "Acme work", priority: .none)
        store.update(acme.id) { $0.github = GitHubRef(repo: "acme/api", number: 1, url: "https://github.com/acme/api/issues/1") }
        let local = store.addTicket(title: "Mine", priority: .none)
        store.addManualEntry(ticketID: acme.id, duration: 3600)
        store.addManualEntry(ticketID: local.id, duration: 1800)
        let range = DateInterval(start: Date().addingTimeInterval(-86_400), end: Date().addingTimeInterval(60))

        XCTAssertEqual(store.trackedTime(in: range), 5400, accuracy: 1)

        store.selectedWorkspace = .organization("acme")
        XCTAssertEqual(store.trackedTime(in: range), 3600, accuracy: 1)
        XCTAssertEqual(store.workspaceTickets.map(\.id), [acme.id])

        store.selectedWorkspace = .personal
        XCTAssertEqual(store.trackedTime(in: range), 1800, accuracy: 1)
    }

    func testHiddenWorkspaceIsExcludedFromAll() {
        let store = makeStore()
        let acme = store.addTicket(title: "Acme work", priority: .none)
        store.update(acme.id) { $0.github = GitHubRef(repo: "acme/api", number: 1, url: "https://github.com/acme/api/issues/1") }
        store.addManualEntry(ticketID: acme.id, duration: 3600)
        let range = DateInterval(start: Date().addingTimeInterval(-86_400), end: Date().addingTimeInterval(60))

        store.setWorkspace(.organization("acme"), visible: false)
        XCTAssertEqual(store.trackedTime(in: range), 0, accuracy: 1)
        XCTAssertTrue(store.workspaceTickets.isEmpty)
    }

    func testCallsAndMeetingsShowInEveryWorkspace() {
        let store = makeStore()
        let acme = store.addTicket(title: "Acme work", priority: .none)
        store.update(acme.id) { $0.github = GitHubRef(repo: "acme/api", number: 1, url: "https://github.com/acme/api/issues/1") }
        let end = Date()
        store.addActivity(kind: .call, title: "Client call", start: end.addingTimeInterval(-1_800), end: end)
        let range = DateInterval(start: end.addingTimeInterval(-3_600), end: end.addingTimeInterval(60))

        for workspace in [Workspace.all, .personal, .organization("acme")] {
            store.selectedWorkspace = workspace
            XCTAssertEqual(store.activityTime(in: range), 1_800, accuracy: 1, "\(workspace.title)")
            XCTAssertEqual(store.log(in: range).count, 1, "\(workspace.title)")
        }

        store.setWorkspace(.personal, visible: false)
        store.selectedWorkspace = .all
        XCTAssertEqual(store.activityTime(in: range), 1_800, accuracy: 1, "hiding Personal must not hide calls")
    }
}
