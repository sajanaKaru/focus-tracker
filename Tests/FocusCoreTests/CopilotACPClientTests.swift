import XCTest
@testable import FocusCore

final class CopilotACPClientTests: XCTestCase {
    private let reply = #"{"cases":[{"title":"Login works","steps":["Open"],"expected":"In"}]}"#
    private let prompt = DraftPrompt(system: "SYS", user: "USER")

    private func client(_ channel: ScriptedChannel, timeout: TimeInterval = 5) -> CopilotACPClient {
        CopilotACPClient(timeout: timeout) { _ in channel }
    }

    private func message(_ channel: ScriptedChannel, method: String) -> [String: Any]? {
        channel.sent.first { $0["method"] as? String == method }
    }

    private func params(_ channel: ScriptedChannel, method: String) -> [String: Any] {
        message(channel, method: method)?["params"] as? [String: Any] ?? [:]
    }

    func testListsEnabledModelsWithoutPrompting() async throws {
        let channel = ScriptedChannel.agent()
        let models = try await client(channel).availableModels()
        XCTAssertEqual(models.map(\.id), ["auto", "claude-y"])
        XCTAssertEqual(channel.methods, ["initialize", "session/new"])
        XCTAssertTrue(channel.closed)
    }

    func testDraftsCasesFromStreamedChunks() async throws {
        let channel = ScriptedChannel.agent(chunks: [String(reply.prefix(20)), String(reply.dropFirst(20))])
        let cases = try await client(channel).draftCases(prompt, model: "claude-y")
        XCTAssertEqual(cases.map(\.title), ["Login works"])
        let blocks = params(channel, method: "session/prompt")["prompt"] as? [[String: Any]]
        XCTAssertTrue((blocks?.first?["text"] as? String)?.hasPrefix("SYS\n\nUSER") == true)
        XCTAssertTrue(channel.closed)
    }

    func testSelectsTheSavedModelWhenItIsEnabled() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        _ = try await client(channel).draftCases(prompt, model: "claude-y")
        XCTAssertEqual(params(channel, method: "session/set_model")["modelId"] as? String, "claude-y")
    }

    func testFallsBackToAutoWhenTheSavedModelIsNotEnabled() async throws {
        let channel = ScriptedChannel.agent(chunks: [reply])
        _ = try await client(channel).draftCases(prompt, model: "gpt-x")
        XCTAssertEqual(params(channel, method: "session/set_model")["modelId"] as? String, "auto")
    }

    func testKeepsTheAccountDefaultWhenAutoIsNotOffered() async throws {
        let models = #"{"availableModels":[{"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled"}}]}"#
        let channel = ScriptedChannel.agent(models: models, chunks: [reply])
        _ = try await client(channel).draftCases(prompt, model: "gone")
        XCTAssertNil(message(channel, method: "session/set_model"))
    }

    func testCancelsEveryPermissionRequest() async throws {
        let request = #"{"jsonrpc":"2.0","id":99,"method":"session/request_permission","params":{"sessionId":"s1"}}"#
        let channel = ScriptedChannel.agent(chunks: [reply], beforeReply: [request])
        _ = try await client(channel).draftCases(prompt, model: "auto")
        let answer = channel.sent.first { ($0["id"] as? Int) == 99 && $0["method"] == nil }
        let outcome = (answer?["result"] as? [String: Any])?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["outcome"] as? String, "cancelled")
    }

    func testSignInProblemsMapToNotSignedIn() async {
        let channel = ScriptedChannel.agent(fail: ["session/new": "Authentication required"])
        do {
            _ = try await client(channel).availableModels()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotNotSignedIn)
        }
        XCTAssertTrue(channel.closed)
    }

    func testQuotaErrorsMapToRateLimited() async {
        let channel = ScriptedChannel.agent(fail: ["session/prompt": "Premium request quota exceeded"])
        do {
            _ = try await client(channel).draftCases(prompt, model: "auto")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .rateLimited(.copilot))
        }
    }

    func testRateLimitMentioningAuthenticatedUserIsRateLimited() async {
        for message in ["API rate limit exceeded for authenticated user", "Too many requests", "Request was rate-limited"] {
            let channel = ScriptedChannel.agent(fail: ["session/new": message])
            do {
                _ = try await client(channel).availableModels()
                XCTFail("expected failure for \(message)")
            } catch {
                XCTAssertEqual(error as? AIError, .rateLimited(.copilot), message)
            }
        }
    }

    func testAuthorizedModelErrorIsNotSignedOut() async {
        let channel = ScriptedChannel.agent(fail: ["session/new": "Not authorized to use model X"])
        do {
            _ = try await client(channel).availableModels()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotFailed("Not authorized to use model X"))
        }
    }

    func testOtherSignInWordingsMapToNotSignedIn() async {
        for message in ["Unauthorized", "User is not authenticated", "Please sign in", "Run copilot login"] {
            let channel = ScriptedChannel.agent(fail: ["session/new": message])
            do {
                _ = try await client(channel).availableModels()
                XCTFail("expected failure for \(message)")
            } catch {
                XCTAssertEqual(error as? AIError, .copilotNotSignedIn, message)
            }
        }
    }

    func testOtherCLIErrorsKeepTheirMessage() async {
        let channel = ScriptedChannel.agent(fail: ["session/prompt": "boom"])
        do {
            _ = try await client(channel).draftCases(prompt, model: "auto")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotFailed("boom"))
        }
    }

    func testAnAccountWithoutEnabledModelsFails() async {
        let channel = ScriptedChannel.agent(models: #"{"availableModels":[]}"#)
        do {
            _ = try await client(channel).availableModels()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotNoEnabledModels)
        }
    }

    func testUnreadableAnswerFails() async {
        let channel = ScriptedChannel.agent(chunks: ["sorry, I can't"])
        do {
            _ = try await client(channel).draftCases(prompt, model: "auto")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .unreadableReply)
        }
    }

    func testTimeoutKillsTheProcess() async {
        let channel = ScriptedChannel { _, _ in [] }
        do {
            _ = try await client(channel, timeout: 0.2).availableModels()
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? AIError, .copilotFailed("The Copilot CLI did not respond in time."))
        }
        XCTAssertTrue(channel.closed)
    }
}
