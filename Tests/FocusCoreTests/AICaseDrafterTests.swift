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
            XCTAssertEqual(error as? AIError, .unreadableReply)
        }
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
}
