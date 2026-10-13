import XCTest
@testable import FocusCore

@MainActor
final class QACodeContextStoreTests: XCTestCase {
    private let detail = #"{"data":{"repository":{"pullRequest":{"title":"Add login","body":"OAuth flow","files":{"nodes":[{"path":"Login.swift"}]}}}}}"#
    private let files = #"[{"filename":"Login.swift","status":"modified","patch":"@@ -1 +1 @@\n-oldLine\n+newLine"}]"#
    private let reply = #"{"choices":[{"message":{"content":"{\"cases\":[{\"title\":\"Login works\"}]}"}}]}"#
    private let pr = LinkedPullRequest(repo: "me/a", number: 9, title: "Add login", url: "u")

    private func makeStore(filesStatus: Int = 200, access: CodeAccess? = nil) -> (AppStore, RecordingTransport) {
        let detail = self.detail, files = self.files, reply = self.reply
        let transport = RecordingTransport { request in
            switch (request.url?.host, request.url?.path.hasSuffix("/files") == true) {
            case ("api.openai.com", _): return (200, reply)
            case ("api.github.com", true): return (filesStatus, filesStatus == 200 ? files : "{}")
            case ("api.github.com", false): return (200, detail)
            default: return (404, "{}")
            }
        }
        let store = AppStore(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json"),
            defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport,
            tokenProvider: { "gh-token" }, aiKeyProvider: { _ in "sk-test" }
        )
        if let access { store.setAICodeAccess(access) }
        return (store, transport)
    }

    private func addTicket(_ store: AppStore) -> Ticket {
        let ticket = Ticket(title: "Login", body: "Users sign in", github: nil)
        store.insertTicketForTest(ticket)
        return ticket
    }

    private func aiBody(_ transport: RecordingTransport) -> String {
        let request = transport.requests.first { $0.url?.host == "api.openai.com" }!
        return String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    func testCodeChangesAreOffByDefaultAndNothingIsFetchedOrSent() async throws {
        let (store, transport) = makeStore()
        XCTAssertEqual(store.aiCodeAccess, .off)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])

        XCTAssertFalse(transport.requests.contains { $0.url?.path.hasSuffix("/files") == true })
        XCTAssertFalse(aiBody(transport).contains("newLine"))
    }

    func testWhenOnTheDiffReachesTheProviderAndTheTokenOnlyGoesToGitHub() async throws {
        let (store, transport) = makeStore(access: .diffs)
        XCTAssertEqual(store.aiCodeAccess, .diffs)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])

        XCTAssertTrue(aiBody(transport).contains("newLine"))
        let filesRequest = transport.requests.first { $0.url?.path == "/repos/me/a/pulls/9/files" }
        XCTAssertEqual(filesRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer gh-token")
        for request in transport.requests where request.url?.host != "api.github.com" {
            XCTAssertFalse((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("gh-token"))
        }
    }

    func testDraftingStillWorksWhenThePatchesCannotBeFetched() async throws {
        let (store, transport) = makeStore(filesStatus: 403, access: .diffs)
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])

        XCTAssertEqual(drafts.map(\.title), ["Login works"])
        XCTAssertTrue(aiBody(transport).contains("OAuth flow"))
        XCTAssertFalse(aiBody(transport).contains("Code changes:"))
    }

    func testNoPullRequestMeansNoPatchFetchEvenWhenOn() async throws {
        let (store, transport) = makeStore(access: .diffs)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
        XCTAssertTrue(transport.requests.allSatisfy { $0.url?.host == "api.openai.com" })
    }

    func testAnOlderSendCodeSettingCountsAsPRChanges() {
        let defaults = UserDefaults(suiteName: "ft-\(UUID().uuidString)")!
        defaults.set(true, forKey: PrefKey.aiIncludeCode)
        let store = AppStore(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json"),
            defaults: defaults, transport: RecordingTransport { _ in (404, "{}") }, tokenProvider: { nil }, aiKeyProvider: { _ in nil }
        )
        XCTAssertEqual(store.aiCodeAccess, .diffs)
        store.setAICodeAccess(.off)
        XCTAssertEqual(store.aiCodeAccess, .off)
    }

    func testDisclosureNamesTheProviderAndGrowsWithTheLevel() {
        let off = CodeAccess.off.disclosure(provider: .anthropic)
        XCTAssertTrue(off.contains("Anthropic"))
        XCTAssertTrue(off.contains("Source code is not sent"))
        XCTAssertTrue(CodeAccess.diffs.disclosure(provider: .copilot).contains("diffs"))
        XCTAssertTrue(CodeAccess.repository.disclosure(provider: .gemini).contains("repository on GitHub"))
        XCTAssertTrue(CodeAccess.repository.sendsDiffs && CodeAccess.repository.readsRepository)
        XCTAssertFalse(CodeAccess.diffs.readsRepository)
    }
}
