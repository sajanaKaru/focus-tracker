import Foundation

public struct LabelOption: Codable, Hashable, Sendable {
    public var name: String
    public var color: String
    public init(name: String, color: String) { self.name = name; self.color = color }
}

public struct MilestoneOption: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var isOpen: Bool
    public var dueOn: Date?
    public init(number: Int, title: String, isOpen: Bool = true, dueOn: Date? = nil) {
        self.number = number; self.title = title; self.isOpen = isOpen; self.dueOn = dueOn
    }
}

public struct FieldOption: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?
    public init(name: String, color: String? = nil) { self.name = name; self.color = color }
}

public struct IssueFieldDefinition: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var dataType: String
    public var options: [FieldOption]
    public init(id: Int, name: String, dataType: String, options: [FieldOption] = []) {
        self.id = id; self.name = name; self.dataType = dataType; self.options = options
    }
}

/// Cached pickers data. Keys: repo and org are lowercased; project is the project title.
public struct RemoteOptions: Codable, Equatable, Sendable {
    public var labels: [String: [LabelOption]] = [:]
    public var milestones: [String: [MilestoneOption]] = [:]
    public var issueFields: [String: [IssueFieldDefinition]] = [:]
    public var projectStatus: [String: [FieldOption]] = [:]
    public init() {}
}
