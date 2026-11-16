import Foundation
@testable import FocusCore

enum ACPFixture {
    /// Duplicate `auto`, one disabled model, as the real CLI reports.
    static let models = #"{"availableModels":[{"modelId":"auto","name":"Auto"},{"modelId":"auto","name":"Auto","_meta":{"copilotEnablement":"enabled","copilotUsage":"1x"}},{"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled","copilotUsage":"15x"}},{"modelId":"gpt-x","name":"GPT X","_meta":{"copilotEnablement":"disabled"}}],"currentModelId":"claude-y"}"#

    static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }
}

/// Stands in for the Copilot CLI: every line the client sends is answered by `respond`.
final class ScriptedChannel: ACPChannel, @unchecked Sendable {
    typealias Responder = @Sendable (_ method: String?, _ message: [String: Any]) -> [String]

    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let respond: Responder
    private let lock = NSLock()
    private var storedSent: [[String: Any]] = []
    private var storedClosed = false

    var sent: [[String: Any]] { lock.withLock { storedSent } }
    var closed: Bool { lock.withLock { storedClosed } }
    var methods: [String] { sent.compactMap { $0["method"] as? String } }

    init(respond: @escaping Responder) {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { captured = $0 }
        continuation = captured
        self.respond = respond
    }

    func send(_ line: Data) throws {
        let message = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        lock.withLock { storedSent.append(message) }
        for reply in respond(message["method"] as? String, message) { continuation.yield(Data(reply.utf8)) }
    }

    func close() {
        lock.withLock { storedClosed = true }
        continuation.finish()
    }

    /// A well-behaved agent. `fail` maps a method name to an error message returned for that method.
    static func agent(
        models: String = ACPFixture.models, chunks: [String] = [], beforeReply: [String] = [], fail: [String: String] = [:]
    ) -> ScriptedChannel {
        ScriptedChannel { method, message in
            guard let method, let id = message["id"] else { return [] }
            func reply(_ result: String) -> String { #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"# }
            if let text = fail[method] {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":\#(ACPFixture.jsonString(text))}}"#]
            }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "session/new": return [reply(#"{"sessionId":"s1","models":\#(models)}"#)]
            case "session/set_model": return [reply("{}")]
            case "session/prompt":
                let updates = chunks.map {
                    #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":\#(ACPFixture.jsonString($0))}}}}"#
                }
                return beforeReply + updates + [reply(#"{"stopReason":"end_turn"}"#)]
            default: return []
            }
        }
    }
}
