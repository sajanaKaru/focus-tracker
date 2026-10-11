import Foundation

public struct LinkedPullRequest: Identifiable, Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String
    public var url: String
    public var state: String

    public var id: String { "\(repo.lowercased())#\(number)" }

    public init(repo: String, number: Int, title: String, url: String, state: String = "OPEN") {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.state = state
    }
}

public struct PullRequestDetail: Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String
    public var body: String
    public var files: [String]

    public init(repo: String, number: Int, title: String, body: String, files: [String]) {
        self.repo = repo
        self.number = number
        self.title = title
        self.body = body
        self.files = files
    }
}

extension GitHubClient {
    /// Pull requests that reference or are connected to the issue, oldest number first.
    public func fetchLinkedPullRequests(repo: String, number: Int) async throws -> [LinkedPullRequest] {
        let (owner, name) = try Self.split(repo)
        let data = try await graphQL(Self.linkedQuery, variables: ["owner": owner, "name": name, "number": number])
        let envelope = try JSONDecoder().decode(LinkedEnvelope.self, from: data)
        if envelope.data == nil, let message = envelope.errors?.first?.message { throw GitHubError.graphQL(message) }
        guard let issue = envelope.data?.repository?.issue else { throw GitHubError.invalidResponse }

        var seen = Set<String>()
        var result: [LinkedPullRequest] = []
        for node in issue.timelineItems.nodes.compactMap({ $0 }) {
            guard let pr = (node.source ?? node.subject)?.toLinked(), seen.insert(pr.id).inserted else { continue }
            result.append(pr)
        }
        return result.sorted { ($0.repo.lowercased(), $0.number) < ($1.repo.lowercased(), $1.number) }
    }

    /// Title, body and up to 100 changed file paths. The diff is not fetched.
    public func fetchPullRequestDetail(repo: String, number: Int) async throws -> PullRequestDetail {
        let (owner, name) = try Self.split(repo)
        let data = try await graphQL(Self.detailQuery, variables: ["owner": owner, "name": name, "number": number])
        let envelope = try JSONDecoder().decode(DetailEnvelope.self, from: data)
        if envelope.data == nil, let message = envelope.errors?.first?.message { throw GitHubError.graphQL(message) }
        guard let pr = envelope.data?.repository?.pullRequest else { throw GitHubError.invalidResponse }
        return PullRequestDetail(repo: repo, number: number, title: pr.title, body: pr.body ?? "", files: pr.files.nodes.compactMap { $0?.path })
    }

    private static func split(_ repo: String) throws -> (String, String) {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { throw GitHubError.invalidResponse }
        return (String(parts[0]), String(parts[1]))
    }

    private static let prFields = "number title url state repository { nameWithOwner }"

    private static let linkedQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          timelineItems(first: 50, itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT]) {
            nodes {
              ... on CrossReferencedEvent { source { ... on PullRequest { \(prFields) } } }
              ... on ConnectedEvent { subject { ... on PullRequest { \(prFields) } } }
            }
          }
        }
      }
    }
    """

    private static let detailQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { title body files(first: 100) { nodes { path } } }
      }
    }
    """
}

private struct GraphQLErrors: Decodable {
    struct Item: Decodable { let message: String }
}

private struct LinkedEnvelope: Decodable {
    struct PR: Decodable {
        let number: Int?
        let title: String?
        let url: String?
        let state: String?
        let repository: Repo?
        struct Repo: Decodable { let nameWithOwner: String }

        func toLinked() -> LinkedPullRequest? {
            guard let number, let title, let url, let repo = repository?.nameWithOwner else { return nil }
            return LinkedPullRequest(repo: repo, number: number, title: title, url: url, state: state ?? "OPEN")
        }
    }
    struct Node: Decodable { let source: PR?; let subject: PR? }
    struct Timeline: Decodable { let nodes: [Node?] }
    struct Issue: Decodable { let timelineItems: Timeline }
    struct Repository: Decodable { let issue: Issue? }
    struct Payload: Decodable { let repository: Repository? }

    let data: Payload?
    let errors: [GraphQLErrors.Item]?
}

private struct DetailEnvelope: Decodable {
    struct File: Decodable { let path: String }
    struct Files: Decodable { let nodes: [File?] }
    struct PR: Decodable { let title: String; let body: String?; let files: Files }
    struct Repository: Decodable { let pullRequest: PR? }
    struct Payload: Decodable { let repository: Repository? }

    let data: Payload?
    let errors: [GraphQLErrors.Item]?
}
