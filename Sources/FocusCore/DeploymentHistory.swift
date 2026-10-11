import Foundation

/// One "moved this from X to Y in Project" entry from an issue's timeline.
public struct StatusMove: Equatable, Sendable {
    public var project: String
    public var from: String
    public var to: String
    public var at: Date
    public var by: String?

    public init(project: String, from: String, to: String, at: Date, by: String? = nil) {
        self.project = project
        self.from = from
        self.to = to
        self.at = at
        self.by = by
    }
}

/// The last time a ticket was moved to a deployment status such as "Merged to Beta".
public struct DeploymentMark: Codable, Hashable, Sendable {
    public var environment: DeploymentEnvironment
    public var statusName: String
    public var movedAt: Date
    public var movedBy: String?

    public init(environment: DeploymentEnvironment, statusName: String, movedAt: Date, movedBy: String? = nil) {
        self.environment = environment
        self.statusName = statusName
        self.movedAt = movedAt
        self.movedBy = movedBy
    }
}

public enum DeploymentHistory {
    /// The latest move into an environment status. `project` limits it to the ticket's own project when known.
    public static func lastDeployment(in moves: [StatusMove], project: String?) -> DeploymentMark? {
        moves
            .filter { project == nil || $0.project == project }
            .compactMap { move in DeploymentEnvironment(deploymentName: move.to).map { (move, $0) } }
            .max { $0.0.at < $1.0.at }
            .map { DeploymentMark(environment: $0.1, statusName: $0.0.to, movedAt: $0.0.at, movedBy: $0.0.by) }
    }
}

extension GitHubClient {
    /// Project status moves per issue node ID (latest 50 each). Issues the response omits are left out of the result.
    public func fetchStatusMoves(nodeIDs: [String]) async throws -> [String: [StatusMove]] {
        var result: [String: [StatusMove]] = [:]
        var firstError: String?
        var gotData = false
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for start in stride(from: 0, to: nodeIDs.count, by: 50) {
            let batch = Array(nodeIDs[start..<min(start + 50, nodeIDs.count)])
            let data = try await graphQL(Self.statusMovesQuery, variables: ["ids": batch])
            let envelope = try decoder.decode(MovesEnvelope.self, from: data)
            firstError = firstError ?? envelope.errors?.first?.message
            guard let nodes = envelope.data?.nodes else { continue }
            gotData = true
            for node in nodes {
                guard let node, let id = node.id, let items = node.timelineItems?.nodes else { continue }
                result[id] = items.compactMap { $0?.toMove() }
            }
        }
        if !gotData, let firstError { throw GitHubError.graphQL(firstError) }
        return result
    }

    private static let statusMovesQuery = """
    query($ids: [ID!]!) {
      nodes(ids: $ids) {
        ... on Issue {
          id
          timelineItems(last: 50, itemTypes: [PROJECT_V2_ITEM_STATUS_CHANGED_EVENT]) {
            nodes {
              ... on ProjectV2ItemStatusChangedEvent {
                createdAt previousStatus status project { title } actor { login }
              }
            }
          }
        }
      }
    }
    """
}

private struct MovesEnvelope: Decodable {
    struct Failure: Decodable { let message: String }
    struct Event: Decodable {
        struct Project: Decodable { let title: String }
        struct Actor: Decodable { let login: String }
        let createdAt: Date?
        let previousStatus: String?
        let status: String?
        let project: Project?
        let actor: Actor?

        func toMove() -> StatusMove? {
            guard let createdAt, let status else { return nil }
            return StatusMove(project: project?.title ?? "", from: previousStatus ?? "", to: status, at: createdAt, by: actor?.login)
        }
    }
    struct Timeline: Decodable { let nodes: [Event?]? }
    struct Node: Decodable { let id: String?; let timelineItems: Timeline? }
    struct Payload: Decodable { let nodes: [Node?]? }

    let data: Payload?
    let errors: [Failure]?
}
