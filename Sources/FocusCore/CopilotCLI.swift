import Foundation

public struct CopilotModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let usage: String?

    /// Name plus the premium-request multiplier, e.g. "Claude Opus 5.5 (15x)".
    public var label: String { usage.map { "\(name) (\($0))" } ?? name }

    /// Models in a `session/new` result that this account can use, without duplicates.
    static func enabled(in result: [String: Any]) -> [CopilotModel] {
        let list = (result["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return list.compactMap { item in
            let meta = item["_meta"] as? [String: Any]
            guard meta?["copilotEnablement"] as? String == "enabled",
                  let id = item["modelId"] as? String, seen.insert(id).inserted else { return nil }
            return CopilotModel(id: id, name: (item["name"] as? String) ?? id, usage: meta?["copilotUsage"] as? String)
        }
    }
}
