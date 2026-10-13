import XCTest
@testable import FocusCore

final class RepoScanLogicTests: XCTestCase {
    func testCandidatePathsDropNoiseAndSecrets() {
        let paths = RepoScan.candidatePaths(["Sources/B.swift", "Sources/A.swift", "package-lock.json", ".env", "keys/app.pem", "node_modules/x/index.js", "dist/app.min.js"])
        XCTAssertEqual(paths, ["Sources/A.swift", "Sources/B.swift"])
    }

    func testCandidatePathsAreCapped() {
        let many = (0..<(RepoScan.maxPaths + 50)).map { "src/file\($0).swift" }
        XCTAssertEqual(RepoScan.candidatePaths(many).count, RepoScan.maxPaths)
    }

    func testSelectionKeepsOnlyKnownUniquePathsUpToTheLimit() {
        let allowed = Set((1...12).map { "f\($0).swift" })
        let reply = #"Sure: {"files":["f1.swift","f1.swift","../etc/passwd","missing.swift","f2.swift","f3.swift","f4.swift","f5.swift","f6.swift","f7.swift","f8.swift","f9.swift"]}"#
        let picked = RepoScan.parseSelection(reply, allowed: allowed)
        XCTAssertEqual(picked.count, RepoScan.maxFiles)
        XCTAssertEqual(Array(picked.prefix(3)), ["f1.swift", "f2.swift", "f3.swift"])
        XCTAssertEqual(RepoScan.parseSelection(#"["f1.swift"]"#, allowed: allowed), ["f1.swift"])
        XCTAssertEqual(RepoScan.parseSelection("no json", allowed: allowed), [])
    }

    func testSelectionPromptCarriesTheContextAndFileList() {
        let base = DraftPrompt(system: "S", user: "Ticket X\n")
        let prompt = RepoScan.selectionPrompt(from: base, paths: ["a.swift", "b.swift"])
        XCTAssertTrue(prompt.user.hasPrefix("Ticket X"))
        XCTAssertTrue(prompt.user.contains("Repository files:\na.swift\nb.swift"))
        XCTAssertTrue(prompt.system.contains("files"))
    }

    func testSectionIsEmptyWithoutFiles() {
        XCTAssertEqual(RepoScan.section(repo: "me/a", files: []), "")
        XCTAssertTrue(RepoScan.section(repo: "me/a", files: [("A.swift", "code")]).contains("--- A.swift\ncode"))
    }
}

@MainActor
final class RepoScanStoreTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)
    private let detail = #"{"data":{"repository":{"pullRequest":{"title":"Add login","body":"OAuth","files":{"nodes":[{"path":"Sources/Login.swift"}]}}}}}"#
    private let pr = LinkedPullRequest(repo: "me/a", number: 9, title: "Add login", url: "u")

    private func openAI(_ content: String) -> String {
        #"{"choices":[{"message":{"content":\#(ACPFixture.jsonString(content))}}]}"#
    }

    private func makeStore(scan: Bool, treeStatus: Int = 200) -> (AppStore, RecordingTransport) {
        let detail = self.detail, sha = self.sha
        let selection = openAI(#"{"files":["Sources/Session.swift",".env","Nope.swift"]}"#)
        let final = openAI(#"{"cases":[{"title":"Old login breaks","risk":"Session changed","steps":["Open"],"expected":"In"}]}"#)
        let tree = #"{"tree":[{"path":"Sources/Login.swift","type":"blob"},{"path":"Sources/Session.swift","type":"blob"},{"path":".env","type":"blob"},{"path":"package-lock.json","type":"blob"},{"path":"Sources","type":"tree"}]}"#
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            if request.url?.host == "api.openai.com" {
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                return (200, body.contains("Repository files:") ? selection : final)
            }
            if path == "/graphql" { return (200, detail) }
            if path == "/repos/me/a/pulls/9" { return (200, #"{"head":{"sha":"\#(sha)"}}"#) }
            if path.hasPrefix("/repos/me/a/git/trees/") { return (treeStatus, treeStatus == 200 ? tree : "{}") }
            if path == "/repos/me/a/contents/Sources/Session.swift" { return (200, "final class Session { func restore() {} }") }
            return (404, "{}")
        }
        let store = AppStore(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json"),
            defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport,
            tokenProvider: { "gh-token" }, aiKeyProvider: { _ in "sk-test" }
        )
        store.setAIScanGitHub(scan)
        return (store, transport)
    }

    private func addTicket(_ store: AppStore) -> Ticket {
        let ticket = Ticket(title: "Login", body: "Users sign in", github: nil)
        store.insertTicketForTest(ticket)
        return ticket
    }

    private func aiBodies(_ transport: RecordingTransport) -> [String] {
        transport.requests.filter { $0.url?.host == "api.openai.com" }
            .map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") }
    }

    func testScanIsOffByDefault() async throws {
        let (store, transport) = makeStore(scan: false)
        XCTAssertFalse(AppStore(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json"),
            defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { nil }, aiKeyProvider: { _ in nil }
        ).aiScanGitHub)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])
        XCTAssertEqual(aiBodies(transport).count, 1)
        XCTAssertFalse(transport.requests.contains { $0.url?.path.contains("/git/trees/") == true })
    }

    func testScanReadsPickedFilesFromGitHubAndAddsThemToTheFinalPrompt() async throws {
        let (store, transport) = makeStore(scan: true)
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr], regression: true)

        XCTAssertEqual(drafts.first?.risk, "Session changed")
        let bodies = aiBodies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("Sources/Session.swift"))
        XCTAssertFalse(bodies[0].contains("package-lock.json"))
        XCTAssertFalse(bodies[0].contains(".env"))
        XCTAssertTrue(bodies[1].contains("Related files in me/a"))
        XCTAssertTrue(bodies[1].contains("final class Session"))

        let contents = transport.requests.filter { $0.url?.path.contains("/contents/") == true }
        XCTAssertEqual(contents.map { $0.url?.path }, ["/repos/me/a/contents/Sources/Session.swift"])
        XCTAssertEqual(contents.first?.url?.query, "ref=\(sha)")
        XCTAssertEqual(contents.first?.value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
        XCTAssertEqual(contents.first?.value(forHTTPHeaderField: "Authorization"), "Bearer gh-token")
        for request in transport.requests where request.url?.host != "api.github.com" {
            XCTAssertFalse((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("gh-token"))
        }
    }

    func testDraftingStillWorksWhenTheScanFails() async throws {
        let (store, transport) = makeStore(scan: true, treeStatus: 403)
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])

        XCTAssertEqual(drafts.map(\.title), ["Old login breaks"])
        XCTAssertEqual(aiBodies(transport).count, 1)
        XCTAssertTrue(store.notice?.contains("Couldn't scan me/a") == true)
    }
}
