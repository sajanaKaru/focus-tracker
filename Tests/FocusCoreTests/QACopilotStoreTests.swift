import XCTest
@testable import FocusCore

@MainActor
final class QACopilotStoreTests: XCTestCase {
    private let reply = #"{"cases":[{"title":"Login works","steps":"Open","expected":"In"},{"title":"Bad password"}]}"#

    private func makeStore(_ channel: ScriptedChannel) -> (AppStore, RecordingTransport) {
        let transport = RecordingTransport { _ in (404, "{}") }
        let store = AppStore(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json"),
            defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport,
            tokenProvider: { "gh-token" }, aiKeyProvider: { _ in nil },
            copilotChannel: { _ in channel }
        )
        store.setAIProvider(.copilot)
        return (store, transport)
    }

    private func addTicket(_ store: AppStore) -> Ticket {
        let ticket = Ticket(title: "Login", body: "Users sign in", github: nil)
        store.insertTicketForTest(ticket)
        return ticket
    }

    func testCopilotNeedsNoAPIKey() {
        let (store, _) = makeStore(.agent())
        XCTAssertTrue(store.hasAIKey)
    }

    func testDraftsThroughCopilotWithoutAnyHTTPRequestOrGitHubToken() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        let (store, transport) = makeStore(channel)
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])

        XCTAssertEqual(drafts.map(\.title), ["Login works", "Bad password"])
        XCTAssertTrue(store.testCases(for: ticket.id).isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: channel.sent), as: UTF8.self)
        XCTAssertTrue(wire.contains("Users sign in"))
        XCTAssertFalse(wire.contains("gh-token"))
    }

    func testUsesTheSavedCopilotModel() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        let (store, _) = makeStore(channel)
        store.setAIModel("claude-y", for: .copilot)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
        let setModel = channel.sent.first { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual((setModel?["params"] as? [String: Any])?["modelId"] as? String, "claude-y")
    }

    func testDefaultsToAutoWhenNoModelIsSaved() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        let (store, _) = makeStore(channel)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
        let setModel = channel.sent.first { $0["method"] as? String == "session/set_model" }
        XCTAssertEqual((setModel?["params"] as? [String: Any])?["modelId"] as? String, "auto")
    }

    func testListsTheEnabledModels() async throws {
        let (store, _) = makeStore(.agent())
        let models = try await store.copilotModels()
        XCTAssertEqual(models.map(\.id), ["auto", "claude-y"])
    }
}
