import XCTest
@testable import FocusCore

final class RepoScanLogicTests: XCTestCase {
    private func files(_ paths: [String], size: Int = 100) -> [RepoFile] {
        paths.map { RepoFile(path: $0, size: size) }
    }

    func testCandidatesDropNoiseSecretsAndBigFiles() {
        let all = files(["Sources/A.swift", "package-lock.json", ".env", "keys/app.pem", "node_modules/x/index.js", "dist/app.min.js"])
            + [RepoFile(path: "data/huge.json", size: RepoScan.maxFileBytes + 1)]
        XCTAssertEqual(RepoScan.candidatePaths(all, near: []), ["Sources/A.swift"])
    }

    func testFilesNearTheChangeComeFirst() {
        let all = files(["Z/last.swift", "A/first.swift", "Sources/Auth/Login.swift", "Sources/Auth/Session.swift", "Sources/Other/X.swift", "Sources/Top.swift"])
        let ranked = RepoScan.candidatePaths(all, near: ["Sources/Auth/Token.swift"])
        XCTAssertEqual(Array(ranked.prefix(2)), ["Sources/Auth/Login.swift", "Sources/Auth/Session.swift"])
        XCTAssertLessThan(ranked.firstIndex(of: "Sources/Top.swift")!, ranked.firstIndex(of: "A/first.swift")!)
        XCTAssertEqual(ranked.count, all.count)
    }

    func testListIsCappedByCountAndCharacters() {
        let many = files((0..<(RepoScan.maxPaths + 50)).map { "s/f\($0)" })
        XCTAssertEqual(RepoScan.candidatePaths(many, near: []).count, RepoScan.maxPaths)
        let longNames = files((0..<400).map { "src/" + String(repeating: "x", count: 200) + "\($0).swift" })
        let capped = RepoScan.candidatePaths(longNames, near: [])
        XCTAssertLessThanOrEqual(capped.joined(separator: "\n").count, RepoScan.maxListChars)
        XCTAssertLessThan(capped.count, 400)
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

    func testSelectionPromptNamesTheRepositoryAndCarriesTheContext() {
        let base = DraftPrompt(system: "S", user: "Ticket X\n")
        let prompt = RepoScan.selectionPrompt(from: base, repo: "me/a", number: 9, paths: ["a.swift", "b.swift"])
        XCTAssertTrue(prompt.user.hasPrefix("Ticket X"))
        XCTAssertTrue(prompt.user.contains("Files in me/a at the latest commit of pull request #9"))
        XCTAssertTrue(prompt.user.hasSuffix("a.swift\nb.swift\n"))
    }

    func testSectionIsEmptyWithoutFiles() {
        XCTAssertEqual(RepoScan.section(repo: "me/a", files: []), "")
        XCTAssertTrue(RepoScan.section(repo: "me/a", files: [("A.swift", "code")]).contains("--- A.swift\ncode"))
    }

    func testSensitivePaths() {
        for path in [".env", ".env.local", "config/server.pem", "id_rsa", ".git/config", ".npmrc", "keys/app.key"] {
            XCTAssertTrue(SensitivePaths.matches(path), path)
        }
        for path in ["Sources/Env.swift", "docs/keys.md", "src/environment.ts"] {
            XCTAssertFalse(SensitivePaths.matches(path), path)
        }
    }
}

@MainActor
final class RepoScanStoreTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)
    private let detail = #"{"data":{"repository":{"pullRequest":{"title":"Add login","body":"OAuth","files":{"nodes":[{"path":"Sources/Login.swift"}]}}}}}"#
    private let patches = #"[{"filename":"Sources/Login.swift","status":"modified","patch":"@@ -1 +1 @@\n-old\n+newLine"}]"#
    private let pr = LinkedPullRequest(repo: "me/a", number: 9, title: "Add login", url: "u")

    private func openAI(_ content: String) -> String {
        #"{"choices":[{"message":{"content":\#(ACPFixture.jsonString(content))}}]}"#
    }

    private func makeStore(_ access: CodeAccess, treeStatus: Int = 200, picks: String = #"{"files":["Sources/Session.swift",".env","Nope.swift"]}"#) -> (AppStore, RecordingTransport) {
        let detail = self.detail, sha = self.sha, patches = self.patches
        let selection = openAI(picks)
        let final = openAI(#"{"cases":[{"title":"Old login breaks","risk":"Session changed","steps":["Open"],"expected":"In"}]}"#)
        let tree = #"{"tree":[{"path":"Sources/Login.swift","type":"blob","size":50},{"path":"Sources/Session.swift","type":"blob","size":50},{"path":".env","type":"blob","size":5},{"path":"package-lock.json","type":"blob","size":9},{"path":"Sources","type":"tree"}]}"#
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            if request.url?.host == "api.openai.com" {
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                return (200, body.contains("Files in me") ? selection : final)
            }
            if path == "/graphql" { return (200, detail) }
            if path == "/repos/me/a/pulls/9/files" { return (200, patches) }
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
        store.setAICodeAccess(access)
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

    func testOffAndDiffLevelsNeverTouchTheRepository() async throws {
        for access in [CodeAccess.off, .diffs] {
            let (store, transport) = makeStore(access)
            let ticket = addTicket(store)
            _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])
            XCTAssertEqual(aiBodies(transport).count, 1, "\(access)")
            XCTAssertFalse(transport.requests.contains { $0.url?.path.contains("/git/trees/") == true }, "\(access)")
            XCTAssertNil(store.draftNote)
        }
    }

    func testRepositoryLevelSendsTheDiffAndReadsPickedFilesFromGitHub() async throws {
        let (store, transport) = makeStore(.repository)
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr], regression: true)

        XCTAssertEqual(drafts.first?.risk, "Session changed")
        let bodies = aiBodies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies[0].contains("newLine"))
        XCTAssertTrue(bodies[0].contains("Files in me/a at the latest commit of pull request #9"))
        XCTAssertTrue(bodies[0].contains("Sources/Session.swift"))
        XCTAssertFalse(bodies[0].contains("package-lock.json"))
        XCTAssertFalse(bodies[0].contains(".env"))
        XCTAssertTrue(bodies[1].contains("Related files in me/a"))
        XCTAssertTrue(bodies[1].contains("final class Session"))
        XCTAssertEqual(store.draftNote, "Read 1 related file from GitHub: me/a/Sources/Session.swift.")

        let contents = transport.requests.filter { $0.url?.path.contains("/contents/") == true }
        XCTAssertEqual(contents.map { $0.url?.path }, ["/repos/me/a/contents/Sources/Session.swift"])
        XCTAssertEqual(contents.first?.url?.query, "ref=\(sha)")
        XCTAssertEqual(contents.first?.value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
        XCTAssertEqual(contents.first?.value(forHTTPHeaderField: "Authorization"), "Bearer gh-token")
        for request in transport.requests where request.url?.host != "api.github.com" {
            XCTAssertFalse((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("gh-token"))
        }
    }

    func testEachFilePickingRequestCarriesOnlyItsOwnPullRequest() async throws {
        let none = openAI(#"{"files":[]}"#)
        let final = openAI(#"{"cases":[{"title":"Old login breaks"}]}"#)
        let tree = #"{"tree":[{"path":"Sources/A.swift","type":"blob","size":10}]}"#
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if request.url?.host == "api.openai.com" { return (200, body.contains("Files in me") ? none : final) }
            if path == "/graphql" {
                let title = body.contains("\"number\":10") ? "Add logout" : "Add login"
                return (200, #"{"data":{"repository":{"pullRequest":{"title":"\#(title)","body":"","files":{"nodes":[]}}}}}"#)
            }
            if path == "/repos/me/a/pulls/9" { return (200, #"{"head":{"sha":"\#(String(repeating: "a", count: 40))"}}"#) }
            if path == "/repos/me/a/pulls/10" { return (200, #"{"head":{"sha":"\#(String(repeating: "b", count: 40))"}}"#) }
            if path.hasPrefix("/repos/me/a/git/trees/") { return (200, tree) }
            return (404, "{}")
        }
        let store = AppStore(
            storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json"),
            defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport,
            tokenProvider: { "gh-token" }, aiKeyProvider: { _ in "sk-test" }
        )
        store.setAICodeAccess(.repository)
        let ticket = addTicket(store)
        let second = LinkedPullRequest(repo: "me/a", number: 10, title: "Add logout", url: "u")
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr, second])

        let bodies = aiBodies(transport)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertTrue(bodies[0].contains("Add login") && !bodies[0].contains("Add logout"))
        XCTAssertTrue(bodies[1].contains("Add logout") && !bodies[1].contains("Add login"))
        XCTAssertTrue(bodies[2].contains("Add login") && bodies[2].contains("Add logout"))
    }

    func testNoteSaysWhenTheAIPickedNothing() async throws {
        let (store, _) = makeStore(.repository, picks: #"{"files":[]}"#)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])
        XCTAssertEqual(store.draftNote, "The AI picked no related files to read.")
    }

    func testNoteSaysWhenThereIsNoPullRequestToRead() async throws {
        let (store, transport) = makeStore(.repository)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [])
        XCTAssertEqual(store.draftNote, "No linked pull request, so no repository files were read.")
        XCTAssertEqual(aiBodies(transport).count, 1)
    }

    func testDraftingStillWorksWhenTheScanFailsAndTheNoteExplainsWhy() async throws {
        let (store, transport) = makeStore(.repository, treeStatus: 403)
        let ticket = addTicket(store)
        let drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])

        XCTAssertEqual(drafts.map(\.title), ["Old login breaks"])
        XCTAssertEqual(aiBodies(transport).count, 1)
        XCTAssertTrue(store.draftNote?.contains("Couldn't scan me/a") == true)
    }

    func testTheNoteIsClearedForTheNextDraft() async throws {
        let (store, _) = makeStore(.repository)
        let ticket = addTicket(store)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])
        XCTAssertNotNil(store.draftNote)
        store.setAICodeAccess(.off)
        _ = try await store.draftTestCases(ticketID: ticket.id, pullRequests: [pr])
        XCTAssertNil(store.draftNote)
    }
}

final class CopilotToolCallTextTests: XCTestCase {
    private let toolCall = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t"}}}"#

    private func chunk(_ text: String) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":\#(ACPFixture.jsonString(text))}}}}"#
    }

    func testTextBeforeAToolCallDoesNotHideTheAnswer() async throws {
        let reply = #"{"cases":[{"title":"Login works","steps":["Open"],"expected":"In"}]}"#
        let channel = ScriptedChannel.agent(chunks: [reply], beforeReply: [chunk("Let me look at { the code"), toolCall])
        let cases = try await CopilotACPClient(timeout: 5) { _ in channel }.draftCases(DraftPrompt(system: "S", user: "U"), model: "auto")
        XCTAssertEqual(cases.map(\.title), ["Login works"])
    }

    func testAnswerBeforeATrailingToolCallIsStillUsed() async throws {
        let channel = ScriptedChannel.agent(beforeReply: [chunk(#"{"cases":[{"title":"Login works"}]}"#), toolCall])
        let cases = try await CopilotACPClient(timeout: 5) { _ in channel }.draftCases(DraftPrompt(system: "S", user: "U"), model: "auto")
        XCTAssertEqual(cases.map(\.title), ["Login works"])
    }
}
