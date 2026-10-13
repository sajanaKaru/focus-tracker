import XCTest
@testable import FocusCore

final class AICaseDrafterTests: XCTestCase {
    private let cases = #"{"cases":[{"title":"Login works","steps":"1. Open app","expected":"Signed in"},{"title":"Bad password","steps":["Enter wrong password","Submit"],"expected":"Error shown"}]}"#

    private func escaped(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [])
        let s = String(decoding: data, as: UTF8.self)
        return String(s.dropFirst().dropLast())
    }

    private func response(for provider: AIProvider, text: String) -> String {
        switch provider {
        case .openAI: #"{"choices":[{"message":{"content":\#(escaped(text))}}]}"#
        case .anthropic: #"{"content":[{"type":"text","text":\#(escaped(text))}]}"#
        case .gemini: #"{"candidates":[{"content":{"parts":[{"text":\#(escaped(text))}]}}]}"#
        case .copilot: ""
        }
    }

    private func draft(_ provider: AIProvider, model: String? = nil, key: String = "secret", status: Int = 200, text: String? = nil) async throws -> ([DraftCase], RecordingTransport) {
        let reply = response(for: provider, text: text ?? cases)
        let transport = RecordingTransport { _ in (status, reply) }
        let client = AICaseClient(provider: provider, model: model ?? provider.defaultModel, apiKey: key, transport: transport)
        let result = try await client.draftCases(DraftPrompt(system: "SYS", user: "USER"))
        return (result, transport)
    }

    // MARK: Requests

    func testOpenAIRequest() async throws {
        let (result, transport) = try await draft(.openAI, model: "gpt-x")
        XCTAssertEqual(result.map(\.title), ["Login works", "Bad password"])
        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = transport.json(0)!
        XCTAssertEqual(body["model"] as? String, "gpt-x")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages[1]["content"], "USER")
    }

    func testAnthropicRequest() async throws {
        let (result, transport) = try await draft(.anthropic, model: "claude-x")
        XCTAssertEqual(result.count, 2)
        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = transport.json(0)!
        XCTAssertEqual(body["model"] as? String, "claude-x")
        XCTAssertEqual(body["system"] as? String, "SYS")
        XCTAssertNotNil(body["max_tokens"])
    }

    func testGeminiRequestKeepsKeyOutOfTheURL() async throws {
        let (result, transport) = try await draft(.gemini, model: "gemini-x")
        XCTAssertEqual(result.count, 2)
        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
        let config = transport.json(0)!["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["responseMimeType"] as? String, "application/json")
    }

    func testGeminiRejectsAModelThatCouldEscapeThePath() async {
        let transport = RecordingTransport { _ in (200, "{}") }
        let client = AICaseClient(provider: .gemini, model: "../x?key=1", apiKey: "k", transport: transport)
        do {
            _ = try await client.draftCases(DraftPrompt(system: "s", user: "u"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .invalidModel)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: Parsing

    func testParsesStepsGivenAsAnArray() async throws {
        let (result, _) = try await draft(.openAI)
        XCTAssertEqual(result[1].steps, "1. Enter wrong password\n2. Submit")
        XCTAssertEqual(result[0].steps, "1. Open app")
    }

    func testParsesFencedJSONAndBareArray() async throws {
        let fenced = "Here you go:\n```json\n" + #"[{"title":"A","steps":"s","expected":"e"}]"# + "\n```"
        for provider in AIProvider.allCases.filter(\.usesAPIKey) {
            let (result, _) = try await draft(provider, text: fenced)
            XCTAssertEqual(result.map(\.title), ["A"], "\(provider)")
        }
    }

    func testSkipsItemsWithoutATitle() async throws {
        let text = #"{"cases":[{"steps":"x"},{"title":"  ","steps":"x"},{"title":"Keep"}]}"#
        let (result, _) = try await draft(.anthropic, text: text)
        XCTAssertEqual(result.map(\.title), ["Keep"])
        XCTAssertEqual(result[0].steps, "")
    }

    func testGarbageReplyFailsAsUnreadable() async {
        do {
            _ = try await draft(.openAI, text: "sorry, I can't")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .unreadableReply("sorry, I can't"))
        }
    }

    func testUnreadableErrorShowsTheStartOfTheReply() {
        let message = AIError.unreadableReply(AIError.preview("line one\nline two " + String(repeating: "x", count: 400))).localizedDescription
        XCTAssertTrue(message.contains("line one line two"))
        XCTAssertLessThan(message.count, 300)
    }

    func testFindsTheJSONAmongStrayBracketsAndBraces() throws {
        let text = """
        Analyzing [regression] risks for {Login}. Here you go:
        ```json
        {"cases":[{"title":"Old login breaks","steps":["Open",2],"expected":["In","Out"]}]}
        ```
        Note: see [1] and {done}.
        """
        let parsed = try AICaseClient.parseCases(text)
        XCTAssertEqual(parsed.map(\.title), ["Old login breaks"])
        XCTAssertEqual(parsed[0].steps, "1. Open\n2. 2")
        XCTAssertEqual(parsed[0].expected, "In\nOut")
    }

    func testBracesInsideStringsDoNotBreakTheMatch() throws {
        let text = #"{"cases":[{"title":"Handles } and ] in names","steps":"Type \"{\""}]}"#
        XCTAssertEqual(try AICaseClient.parseCases(text).map(\.title), ["Handles } and ] in names"])
    }

    func testEmptyCaseListFails() async {
        do {
            _ = try await draft(.gemini, text: #"{"cases":[]}"#)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .noCases)
        }
    }

    // MARK: Errors

    func testHTTPStatusesMapToErrors() async {
        for (status, expected) in [(401, AIError.unauthorized(.openAI)), (403, .unauthorized(.openAI)), (429, .rateLimited(.openAI)), (500, .http(500, .openAI))] {
            do {
                _ = try await draft(.openAI, status: status)
                XCTFail("expected failure for \(status)")
            } catch {
                XCTAssertEqual(error as? AIError, expected)
            }
        }
    }

    func testErrorMessagesNameTheProvider() {
        XCTAssertTrue(AIError.missingKey(.gemini).localizedDescription.contains("Gemini"))
        XCTAssertTrue(AIError.unauthorized(.anthropic).localizedDescription.contains("Anthropic"))
    }

    // MARK: Prompt

    func testPromptIncludesTicketAndPullRequestDetails() {
        let pr = PullRequestDetail(repo: "me/a", number: 9, title: "Add login", body: "Adds OAuth", files: ["Sources/Login.swift", "Sources/Auth.swift"])
        let prompt = DraftPrompt.make(ticketKey: "me/a#4", title: "Login", body: "Users need to sign in", pullRequests: [pr])
        XCTAssertTrue(prompt.user.contains("me/a#4"))
        XCTAssertTrue(prompt.user.contains("Users need to sign in"))
        XCTAssertTrue(prompt.user.contains("Add login"))
        XCTAssertTrue(prompt.user.contains("Adds OAuth"))
        XCTAssertTrue(prompt.user.contains("Sources/Login.swift"))
        XCTAssertTrue(prompt.system.contains("JSON"))
    }

    func testRegressionPromptSharesContextAndMarksCases() throws {
        let pr = PullRequestDetail(repo: "me/a", number: 9, title: "Add login", body: "Adds OAuth", files: ["Sources/Login.swift"])
        let prompt = DraftPrompt.makeRegression(ticketKey: "me/a#4", title: "Login", body: "Users need to sign in", pullRequests: [pr])
        XCTAssertTrue(prompt.regression)
        XCTAssertTrue(prompt.user.contains("Sources/Login.swift"))
        XCTAssertTrue(prompt.system.contains("regression"))

        let text = #"{"cases":[{"title":"Old login breaks","risk":"Shared session code changed","steps":["Open app","Sign in with email"],"expected":"Signed in"}]}"#
        let parsed = try AICaseClient.parseCases(text, regression: prompt.regression)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed[0].isRegression)
        XCTAssertEqual(parsed[0].risk, "Shared session code changed")
        XCTAssertEqual(parsed[0].steps, "1. Open app\n2. Sign in with email")
    }

    func testPlainDraftsAreNotRegressions() throws {
        let parsed = try AICaseClient.parseCases(cases)
        XCTAssertFalse(parsed[0].isRegression)
        XCTAssertEqual(parsed[0].risk, "")
    }

    func testTestCaseDecodesWithoutRegressionFields() throws {
        let id = UUID(), ticket = UUID()
        let json = #"{"id":"\#(id)","ticketID":"\#(ticket)","title":"T","steps":"s","expected":"e","createdAt":0}"#
        let decoded = try JSONDecoder().decode(TestCase.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isRegression)
        XCTAssertEqual(decoded.risk, "")
    }

    func testPromptWithoutPullRequestsSaysSo() {
        let prompt = DraftPrompt.make(ticketKey: "me/a#4", title: "Login", body: "", pullRequests: [])
        XCTAssertTrue(prompt.user.contains("No linked pull request"))
    }

    func testPromptTruncatesLongBodiesAndFileLists() {
        let long = String(repeating: "x", count: 20_000)
        let files = (0..<300).map { "file\($0).swift" }
        let pr = PullRequestDetail(repo: "me/a", number: 9, title: "T", body: long, files: files)
        let prompt = DraftPrompt.make(ticketKey: "k", title: "T", body: long, pullRequests: [pr])
        XCTAssertLessThan(prompt.user.count, 14_000)
        XCTAssertTrue(prompt.user.contains("file99.swift"))
        XCTAssertFalse(prompt.user.contains("file100.swift"))
    }

    // MARK: Code changes

    private func pr(_ patches: [PullRequestFilePatch]) -> PullRequestDetail {
        PullRequestDetail(repo: "me/a", number: 9, title: "T", body: "", files: patches.map(\.path), patches: patches)
    }

    func testPromptIncludesCodeChangesAndTellsTheModelToUseThem() {
        let patch = PullRequestFilePatch(path: "Sources/Login.swift", status: "modified", patch: "@@ -1 +1 @@\n-old\n+new")
        let prompt = DraftPrompt.make(ticketKey: "k", title: "T", body: "", pullRequests: [pr([patch])])
        XCTAssertTrue(prompt.user.contains("Code changes:"))
        XCTAssertTrue(prompt.user.contains("--- Sources/Login.swift (modified)"))
        XCTAssertTrue(prompt.user.contains("+new"))
        XCTAssertTrue(prompt.system.contains("code changes"))
    }

    func testPromptWithoutPatchesHasNoCodeSectionAndTheOriginalInstructions() {
        let plain = DraftPrompt.make(ticketKey: "k", title: "T", body: "", pullRequests: [pr([])])
        let binaryOnly = DraftPrompt.make(ticketKey: "k", title: "T", body: "", pullRequests: [pr([PullRequestFilePatch(path: "a.bin", status: "added", patch: nil)])])
        for prompt in [plain, binaryOnly] {
            XCTAssertFalse(prompt.user.contains("Code changes:"))
            XCTAssertFalse(prompt.system.contains("code changes"))
        }
    }

    func testPromptSkipsLockfilesGeneratedFilesAndImages() {
        let names = ["Package.resolved", "web/package-lock.json", "app.min.js", "Pods/X/y.swift", "logo.PNG", "App.xcodeproj/project.pbxproj"]
        let noise = names.map { PullRequestFilePatch(path: $0, status: "modified", patch: "+noise") }
        let keep = PullRequestFilePatch(path: "Sources/Real.swift", status: "added", patch: "+real")
        let prompt = DraftPrompt.make(ticketKey: "k", title: "T", body: "", pullRequests: [pr(noise + [keep])])
        XCTAssertTrue(prompt.user.contains("+real"))
        XCTAssertFalse(prompt.user.contains("+noise"))
        XCTAssertFalse(prompt.user.contains("more changed files"))
    }

    func testPromptClipsEachPatchAndTheTotal() {
        let big = String(repeating: "y", count: 10_000)
        let one = DraftPrompt.make(ticketKey: "k", title: "T", body: "", pullRequests: [pr([PullRequestFilePatch(path: "a.swift", status: "added", patch: big)])])
        XCTAssertLessThan(one.user.count, 5_000)

        let many = (0..<20).map { PullRequestFilePatch(path: "f\($0).swift", status: "added", patch: big) }
        let prompt = DraftPrompt.make(ticketKey: "k", title: "T", body: "", pullRequests: [pr(many)])
        XCTAssertLessThan(prompt.user.count, 27_000)
        XCTAssertTrue(prompt.user.contains("f0.swift"))
        XCTAssertTrue(prompt.user.contains("more changed files not shown"))
        XCTAssertFalse(prompt.user.contains("--- f19.swift"))
    }

    func testTheTotalBudgetIsSharedAcrossPullRequests() {
        let big = String(repeating: "z", count: 4_000)
        let files = (0..<5).map { PullRequestFilePatch(path: "g\($0).swift", status: "added", patch: big) }
        let first = pr(files), second = PullRequestDetail(repo: "me/b", number: 3, title: "U", body: "", files: ["h.swift"], patches: [PullRequestFilePatch(path: "h.swift", status: "added", patch: big)])
        let prompt = DraftPrompt.make(ticketKey: "k", title: "T", body: "", pullRequests: [first, first, first, first, first, second])
        XCTAssertLessThan(prompt.user.count, 30_000)
    }
}
