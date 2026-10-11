import XCTest
@testable import FocusCore

@MainActor
final class QADraftStoreTests: XCTestCase {
    private let detail = #"{"data":{"repository":{"pullRequest":{"title":"Add login","body":"OAuth flow","files":{"nodes":[{"path":"Login.swift"}]}}}}}"#
    private let linked = #"{"data":{"repository":{"issue":{"timelineItems":{"nodes":[{"source":{"number":9,"title":"Add login","url":"u","state":"OPEN","repository":{"nameWithOwner":"me/a"}}}]}}}}}"#
    private let reply = #"{"choices":[{"message":{"content":"{\"cases\":[{\"title\":\"Login works\",\"steps\":\"Open\",\"expected\":\"In\"},{\"title\":\"Bad password\"}]}"}}]}"#

    private func makeStore(
        key: String? = "sk-test", defaults: UserDefaults? = nil,
        _ handler: (@Sendable (URLRequest) -> (Int, String))? = nil
    ) -> (AppStore, RecordingTransport) {
        let detail = self.detail, linked = self.linked, reply = self.reply
        let transport = RecordingTransport(handler ?? { request in
            switch request.url?.host {
            case "api.openai.com": return (200, reply)
            case "api.github.com":
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                return (200, body.contains("timelineItems") ? linked : detail)
            default: return (404, "{}")
            }
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(
            storeURL: url, defaults: defaults ?? UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport,
            tokenProvider: { "gh-token" }, aiKeyProvider: { _ in key }
        )
        return (store, transport)
    }

    private func addTicket(_ store: AppStore, github: Bool = true) -> Ticket {
        let ticket = Ticket(
            title: "Login", body: "Users sign in",
            github: github ? GitHubRef(repo: "me/a", number: 4, url: "https://github.com/me/a/issues/4") : nil
        )
        store.insertTicketForTest(ticket)
        return ticket
    }

    private let pr = LinkedPullRequest(repo: "me/a", number: 9, title: "Add login", url: "u")

    func testDraftsFromTicketAndPullRequestWithoutSavingAnything() async throws {
        let (store, transport) = makeStore()
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])

        XCTAssertEqual(drafts.map(\.title), ["Login works", "Bad password"])
        XCTAssertTrue(store.testCases(for: ticket.id).isEmpty)

        let ai = transport.requests.first { $0.url?.host == "api.openai.com" }!
        XCTAssertEqual(ai.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let messages = (try! JSONSerialization.jsonObject(with: ai.httpBody!) as! [String: Any])["messages"] as! [[String: String]]
        XCTAssertTrue(messages[1]["content"]!.contains("Users sign in"))
        XCTAssertTrue(messages[1]["content"]!.contains("OAuth flow"))
        XCTAssertTrue(messages[1]["content"]!.contains("Login.swift"))

        let github = transport.requests.filter { $0.url?.host == "api.github.com" }
        XCTAssertTrue(github.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer gh-token" })
    }

    func testTheGitHubTokenIsNeverSentToTheAIProvider() async throws {
        let (store, transport) = makeStore()
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])
        for request in transport.requests where request.url?.host != "api.github.com" {
            XCTAssertFalse((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("gh-token"))
        }
    }

    func testDraftsFromTicketTextWhenThereAreNoPullRequests() async throws {
        let (store, transport) = makeStore()
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertTrue(transport.requests.allSatisfy { $0.url?.host == "api.openai.com" })
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let (store, transport) = makeStore(key: nil)
        let ticket = addTicket(store)
        do {
            _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .missingKey(.openAI))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testBlankKeyCountsAsMissing() async {
        let (store, _) = makeStore(key: "  ")
        let ticket = addTicket(store)
        do {
            _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .missingKey(.openAI))
        }
    }

    func testProviderErrorSurfaces() async {
        let (store, _) = makeStore { _ in (429, "{}") }
        let ticket = addTicket(store, github: false)
        do {
            _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .rateLimited(.openAI))
        }
    }

    func testUsesTheConfiguredProviderAndModel() async throws {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        let (store, transport) = makeStore(defaults: defaults) { _ in
            (200, #"{"content":[{"type":"text","text":"{\"cases\":[{\"title\":\"A\"}]}"}]}"#)
        }
        store.setAIProvider(.anthropic)
        store.setAIModel("claude-custom", for: .anthropic)
        let ticket = addTicket(store, github: false)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])

        XCTAssertEqual(transport.requests[0].url?.host, "api.anthropic.com")
        XCTAssertEqual(transport.json(0)?["model"] as? String, "claude-custom")
    }

    func testProviderAndModelDefaults() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.aiProvider, .openAI)
        XCTAssertEqual(store.aiModel(for: .gemini), AIProvider.gemini.defaultModel)
        store.setAIModel("  ", for: .gemini)
        XCTAssertEqual(store.aiModel(for: .gemini), AIProvider.gemini.defaultModel)
    }

    func testListsLinkedPullRequestsAndSkipsTicketsWithoutGitHub() async throws {
        let (store, _) = makeStore()
        let ticket = addTicket(store)
        let local = addTicket(store, github: false)
        let prs = try await store.linkedPullRequests(for: ticket.id)
        XCTAssertEqual(prs.map(\.id), ["me/a#9"])
        let none = try await store.linkedPullRequests(for: local.id)
        XCTAssertTrue(none.isEmpty)
    }

    func testAddDraftsSavesOnlyTheGivenCasesAndLogsThem() {
        let (store, _) = makeStore()
        let ticket = addTicket(store)
        let added = store.addDrafts(
            ticketID: ticket.id,
            [DraftCase(title: "One", steps: "s", expected: "e"), DraftCase(title: "  "), DraftCase(title: "Two")]
        )
        XCTAssertEqual(added, 2)
        let cases = store.testCases(for: ticket.id)
        XCTAssertEqual(cases.map(\.title), ["One", "Two"])
        XCTAssertEqual(cases[0].steps, "s")
        XCTAssertEqual(store.actionLog.filter { $0.kind == .testCase }.count, 2)
    }
}
