import Foundation

public struct RemoteIssue: Equatable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String
    public var body: String
    public var labels: [String]
    public var labelColors: [String: String]
    public var url: String
    public var isPullRequest: Bool
    public var nodeID: String
    public var milestone: Milestone?
    /// nil means "not fetched"; an empty array means the issue has no project fields.
    public var fields: [CustomField]?
    public var issueType: IssueType?
    /// nil means "not fetched"; see `GitHubClient.fetchIssueFields`.
    public var issueFields: [CustomField]?
    public var isOpen: Bool

    public var key: String { "\(repo.lowercased())#\(number)" }

    public init(repo: String, number: Int, title: String, body: String = "", labels: [String] = [], labelColors: [String: String] = [:], url: String, isPullRequest: Bool = false, nodeID: String = "", milestone: Milestone? = nil, fields: [CustomField]? = nil, issueType: IssueType? = nil, issueFields: [CustomField]? = nil, isOpen: Bool = true) {
        self.repo = repo
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels
        self.labelColors = labelColors
        self.url = url
        self.isPullRequest = isPullRequest
        self.nodeID = nodeID
        self.milestone = milestone
        self.fields = fields
        self.issueType = issueType
        self.issueFields = issueFields
        self.isOpen = isOpen
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum ProjectFieldValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case option(String)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        return (data, http)
    }
}

public enum GitHubError: LocalizedError {
    case unauthorized
    case rateLimited
    case http(Int)
    case invalidResponse
    case graphQL(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub rejected the token. Check it in Settings."
        case .rateLimited: "GitHub rate limit reached. Try again later."
        case .http(let code): "GitHub returned HTTP \(code)."
        case .invalidResponse: "Unexpected response from GitHub."
        case .graphQL(let message): message
        }
    }
}

public struct GitHubClient: Sendable {
    public static let apiHost = "api.github.com"

    private let token: String
    private let transport: HTTPTransport
    private let maxPages = 20

    public init(token: String, transport: HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    public func currentUser() async throws -> String {
        struct User: Decodable { let login: String }
        let (data, _) = try await get(URL(string: "https://\(Self.apiHost)/user")!)
        return try JSONDecoder().decode(User.self, from: data).login
    }

    /// Open issues assigned to the authenticated user across all accessible repos.
    /// `repos` (lowercased "owner/name") restricts the result when non-empty.
    public func fetchAssignedIssues(repos: Set<String> = [], includePullRequests: Bool = false) async throws -> [RemoteIssue] {
        var components = URLComponents(string: "https://\(Self.apiHost)/issues")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "assigned"),
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "per_page", value: "100")
        ]
        var next: URL? = components.url
        var result: [RemoteIssue] = []
        var pages = 0

        while let url = next, pages < maxPages {
            let (data, response) = try await get(url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([IssueDTO].self, from: data)
            for item in items {
                guard let issue = item.toRemote() else { continue }
                if issue.isPullRequest && !includePullRequests { continue }
                if !repos.isEmpty && !repos.contains(issue.repo.lowercased()) { continue }
                result.append(issue)
            }
            next = Self.nextURL(from: response.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return result
    }

    /// Latest state of one issue, e.g. when the user opens a ticket.
    public func fetchIssue(repo: String, number: Int) async throws -> RemoteIssue {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/issues/\(number)") else {
            throw GitHubError.invalidResponse
        }
        let (data, _) = try await get(url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        guard let issue = try decoder.decode(IssueDTO.self, from: data).toRemote() else { throw GitHubError.invalidResponse }
        return issue
    }

    /// Organization issue fields (Priority, Effort, Start date, Target date, ...) for one issue.
    public func fetchIssueFields(repo: String, number: Int) async throws -> [CustomField] {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/issues/\(number)/issue-field-values?per_page=100") else {
            throw GitHubError.invalidResponse
        }
        let (data, _) = try await get(url, apiVersion: Self.issueFieldsAPIVersion)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([IssueFieldValueDTO].self, from: data).compactMap { $0.toField() }
    }

    /// Issue fields for many issues, a few requests at a time. Issues whose request fails are left out.
    public func fetchIssueFields(for issues: [RemoteIssue], concurrency: Int = 6) async -> [String: [CustomField]] {
        var result: [String: [CustomField]] = [:]
        await withTaskGroup(of: (String, [CustomField]?).self) { group in
            var iterator = issues.makeIterator()
            func addNext() {
                guard let issue = iterator.next() else { return }
                group.addTask { (issue.key, try? await fetchIssueFields(repo: issue.repo, number: issue.number)) }
            }
            for _ in 0..<concurrency { addNext() }
            while let (key, fields) = await group.next() {
                if let fields { result[key] = fields }
                addNext()
            }
        }
        return result
    }

    private static let issueFieldsAPIVersion = "2026-03-10"

    /// Project (v2) field values such as Sprint, Estimate and RCA, keyed by issue node ID.
    /// Needs the `read:project` scope; issues outside any project map to an empty array.
    public func fetchProjectFields(nodeIDs: [String]) async throws -> [String: [CustomField]] {
        var result: [String: [CustomField]] = [:]
        var firstError: String?
        let url = URL(string: "https://\(Self.apiHost)/graphql")!

        for start in stride(from: 0, to: nodeIDs.count, by: 50) {
            let batch = Array(nodeIDs[start..<min(start + 50, nodeIDs.count)])
            let body = try JSONEncoder().encode(GraphQLRequest(query: Self.projectFieldsQuery, variables: ["ids": batch]))
            let data = try await send(post: url, body: body)
            let envelope = try JSONDecoder().decode(GraphQLEnvelope.self, from: data)
            firstError = firstError ?? envelope.errors?.first?.message
            for node in envelope.data?.nodes ?? [] {
                guard let node, let id = node.id else { continue }
                result[id] = node.customFields()
            }
        }

        if let firstError, result.values.allSatisfy(\.isEmpty) { throw GitHubError.graphQL(firstError) }
        return result
    }

    private static let projectFieldsQuery = """
    query($ids: [ID!]!) {
      nodes(ids: $ids) {
        ... on Issue { \(Self.selection) }
        ... on PullRequest { \(Self.selection) }
      }
    }
    """

    private static let selection = """
    id
    projectItems(first: 20) {
      nodes {
        project { title rca: field(name: "\(CustomField.rcaName)") { ... on ProjectV2FieldCommon { name } } }
        fieldValues(first: 50) {
          nodes {
            ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
            ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
            ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
            ... on ProjectV2ItemFieldSingleSelectValue { name color field { ... on ProjectV2FieldCommon { name } } }
            ... on ProjectV2ItemFieldIterationValue { title startDate duration field { ... on ProjectV2FieldCommon { name } } }
          }
        }
      }
    }
    """

    private static let fieldLookupQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          projectItems(first: 20) {
            nodes {
              id
              project { id title fields(first: 50) { nodes { ... on ProjectV2FieldCommon { id name } } } }
            }
          }
        }
      }
    }
    """

    private static let setFieldMutation = """
    mutation($project: ID!, $item: ID!, $field: ID!, $value: ProjectV2FieldValue!) {
      updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field, value: $value}) { projectV2Item { id } }
    }
    """

    private static let clearFieldMutation = """
    mutation($project: ID!, $item: ID!, $field: ID!) {
      clearProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field}) { projectV2Item { id } }
    }
    """

    /// Writes a text or number value to a Projects (v2) field on the issue. Needs a token with write access to projects.
    public func updateProjectField(repo: String, number: Int, project: String, field: String, value: ProjectFieldValue) async throws {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { throw GitHubError.invalidResponse }

        let lookupData = try await graphQL(Self.fieldLookupQuery, variables: ["owner": String(parts[0]), "name": String(parts[1]), "number": number])
        let lookup = try JSONDecoder().decode(FieldLookup.self, from: lookupData)
        if let message = lookup.errors?.first?.message { throw GitHubError.graphQL(message) }

        let items = (lookup.data?.repository?.issue?.projectItems.nodes ?? []).compactMap { $0 }
        guard let item = items.first(where: { $0.project.title == project }) else {
            throw GitHubError.graphQL("This issue is not in the \"\(project)\" project.")
        }
        guard let fieldID = (item.project.fields.nodes ?? []).compactMap({ $0 }).first(where: { $0.name == field })?.id else {
            throw GitHubError.graphQL("The \"\(project)\" project has no \"\(field)\" field.")
        }

        let ids: [String: Any] = ["project": item.project.id, "item": item.id, "field": fieldID]
        let result: Data
        switch value {
        case .text(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            result = try await graphQL(Self.clearFieldMutation, variables: ids)
        case .text(let text):
            result = try await graphQL(Self.setFieldMutation, variables: ids.merging(["value": ["text": text]]) { $1 })
        case .number(let number):
            result = try await graphQL(Self.setFieldMutation, variables: ids.merging(["value": ["number": number]]) { $1 })
        case .option:
            throw GitHubError.invalidResponse
        }
        if let message = try JSONDecoder().decode(FieldLookup.self, from: result).errors?.first?.message {
            throw GitHubError.graphQL(message)
        }
    }

    /// Posts a comment on the issue. Needs a token that can write issues.
    public func postComment(repo: String, number: Int, body: String) async throws {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/issues/\(number)/comments") else {
            throw GitHubError.invalidResponse
        }
        _ = try await send(post: url, body: JSONEncoder().encode(["body": body]))
    }

    /// Open pull requests authored by `login` (first 100, most recently updated first) with review, CI and conflict state.
    public func fetchOpenPullRequests(authoredBy login: String) async throws -> (items: [PullRequestItem], total: Int) {
        let search = "is:pr is:open author:\(login) archived:false sort:updated-desc"
        let data = try await graphQL(Self.pullRequestsQuery, variables: ["q": search])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(PullRequestsEnvelope.self, from: data)
        if envelope.data == nil, let message = envelope.errors?.first?.message { throw GitHubError.graphQL(message) }
        guard let result = envelope.data?.search else { throw GitHubError.invalidResponse }
        return (result.nodes.compactMap { $0?.toItem() }, result.issueCount)
    }

    private static let pullRequestsQuery = """
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 100) {
        issueCount
        nodes {
          ... on PullRequest {
            number title url isDraft createdAt updatedAt reviewDecision mergeable
            repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    private func graphQL(_ query: String, variables: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        return try await send(post: URL(string: "https://\(Self.apiHost)/graphql")!, body: body)
    }

    private func get(_ url: URL, apiVersion: String = "2022-11-28") async throws -> (Data, HTTPURLResponse) {
        try await send(request(for: url, apiVersion: apiVersion))
    }

    private func send(post url: URL, body: Data) async throws -> Data {
        var request = request(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await send(request).0
    }

    private func request(for url: URL, apiVersion: String = "2022-11-28") -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FocusTracker", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: return (data, response)
        case 401: throw GitHubError.unauthorized
        case 403, 429:
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || response.statusCode == 429 {
                throw GitHubError.rateLimited
            }
            throw GitHubError.http(response.statusCode)
        default: throw GitHubError.http(response.statusCode)
        }
    }

    /// Parses `<url>; rel="next"` and refuses hosts other than api.github.com so the token never leaks.
    static func nextURL(from link: String?) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            let raw = String(part[part.index(after: start)..<end])
            guard let url = URL(string: raw), url.scheme == "https", url.host == apiHost else { return nil }
            return url
        }
        return nil
    }
}

private struct IssueDTO: Decodable {
    struct Label: Decodable { let name: String; let color: String? }
    struct MilestoneDTO: Decodable {
        let title: String
        let state: String?
        let dueOn: Date?
    }
    struct PullRequestMarker: Decodable {}
    struct TypeDTO: Decodable {
        let name: String
        let color: String?
    }

    let number: Int
    let title: String
    let body: String?
    let htmlUrl: String
    let repositoryUrl: String
    let nodeId: String?
    let state: String?
    let type: TypeDTO?
    let labels: [Label]
    let milestone: MilestoneDTO?
    let pullRequest: PullRequestMarker?

    func toRemote() -> RemoteIssue? {
        let marker = "/repos/"
        guard let range = repositoryUrl.range(of: marker) else { return nil }
        let repo = String(repositoryUrl[range.upperBound...])
        return RemoteIssue(
            repo: repo,
            number: number,
            title: title,
            body: body ?? "",
            labels: labels.map(\.name),
            labelColors: Dictionary(labels.compactMap { l in l.color.map { (l.name, $0) } }, uniquingKeysWith: { first, _ in first }),
            url: htmlUrl,
            isPullRequest: pullRequest != nil,
            nodeID: nodeId ?? "",
            milestone: milestone.map { Milestone(title: $0.title, isOpen: $0.state != "closed", dueOn: $0.dueOn) },
            issueType: type.map { IssueType(name: $0.name, color: $0.color) },
            isOpen: state != "closed"
        )
    }
}

private struct IssueFieldValueDTO: Decodable {
    struct Option: Decodable {
        let name: String
        let color: String?
    }
    struct Scalar: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                text = number == number.rounded() ? String(Int(number)) : String(number)
            } else {
                text = try container.decode(String.self)
            }
        }
    }

    let issueFieldName: String?
    let dataType: String
    let value: Scalar?
    let singleSelectOption: Option?
    let multiSelectOptions: [Option]?

    func toField() -> CustomField? {
        guard let name = issueFieldName else { return nil }
        let group = CustomField.issueFieldsGroup
        switch dataType {
        case "single_select":
            guard let label = singleSelectOption?.name ?? value?.text else { return nil }
            return CustomField(name: name, value: label, kind: .select, project: group, color: singleSelectOption?.color)
        case "multi_select":
            let labels = (multiSelectOptions ?? []).map(\.name)
            return labels.isEmpty ? nil : CustomField(name: name, value: labels.joined(separator: ", "), kind: .select, project: group)
        case "date":
            guard let text = value?.text else { return nil }
            return CustomField(name: name, value: String(text.prefix(10)), kind: .date, project: group, start: parseDay(text))
        case "number":
            return value.map { CustomField(name: name, value: $0.text, kind: .number, project: group) }
        default:
            guard let text = value?.text, !text.isEmpty else { return nil }
            return CustomField(name: name, value: text, kind: .text, project: group)
        }
    }
}

/// Parses the leading `yyyy-MM-dd` of a GitHub date as a local calendar day.
private func parseDay(_ text: String) -> Date? {
    let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: [String]]
}

private struct GraphQLEnvelope: Decodable {
    struct Failure: Decodable { let message: String }
    struct DataNode: Decodable { let nodes: [ContentNode?]? }

    let data: DataNode?
    let errors: [Failure]?
}

private struct FieldLookup: Decodable {
    struct Failure: Decodable { let message: String }
    struct Root: Decodable { let repository: Repository? }
    struct Repository: Decodable { let issue: Issue? }
    struct Issue: Decodable { let projectItems: Items }
    struct Items: Decodable { let nodes: [Item?]? }
    struct Item: Decodable {
        let id: String
        let project: Project
    }
    struct Project: Decodable {
        let id: String
        let title: String
        let fields: Fields
    }
    struct Fields: Decodable { let nodes: [Field?]? }
    struct Field: Decodable {
        let id: String?
        let name: String?
    }

    let data: Root?
    let errors: [Failure]?
}

private struct ContentNode: Decodable {
    struct ProjectItems: Decodable { let nodes: [Item?]? }
    struct Item: Decodable {
        struct Project: Decodable {
            struct FieldName: Decodable { let name: String? }
            let title: String
            let rca: FieldName?
        }
        struct FieldValues: Decodable { let nodes: [Value?]? }
        struct Value: Decodable {
            struct FieldRef: Decodable { let name: String? }
            let text: String?
            let number: Double?
            let date: String?
            let name: String?
            let title: String?
            let startDate: String?
            let duration: Int?
            let color: String?
            let field: FieldRef?
        }
        let project: Project?
        let fieldValues: FieldValues?
    }

    let id: String?
    let projectItems: ProjectItems?

    func customFields() -> [CustomField] {
        var fields: [CustomField] = []
        for item in projectItems?.nodes ?? [] {
            guard let item else { continue }
            let project = item.project?.title ?? ""
            for value in item.fieldValues?.nodes ?? [] {
                guard let value, let name = value.field?.name, name != "Title" else { continue }
                if let title = value.title, let startText = value.startDate, let start = parseDay(startText) {
                    let end = Calendar.current.date(byAdding: .day, value: value.duration ?? 0, to: start)
                    fields.append(CustomField(name: name, value: title, kind: .iteration, project: project, start: start, end: end))
                } else if let option = value.name {
                    fields.append(CustomField(name: name, value: option, kind: .select, project: project, color: value.color?.lowercased()))
                } else if let number = value.number {
                    let text = number == number.rounded() ? String(Int(number)) : String(number)
                    fields.append(CustomField(name: name, value: text, kind: .number, project: project))
                } else if let date = value.date {
                    fields.append(CustomField(name: name, value: date, kind: .date, project: project, start: parseDay(date)))
                } else if let text = value.text, !text.isEmpty {
                    fields.append(CustomField(name: name, value: text, kind: .text, project: project))
                }
            }
            // An RCA field with no value yet is still editable.
            if item.project?.rca?.name != nil, !fields.contains(where: { $0.project == project && $0.name == CustomField.rcaName }) {
                fields.append(CustomField(name: CustomField.rcaName, value: "", kind: .text, project: project))
            }
        }
        return fields
    }
}

private struct PullRequestsEnvelope: Decodable {
    struct Failure: Decodable { let message: String }
    struct Search: Decodable {
        let issueCount: Int
        let nodes: [Node?]
    }
    struct Node: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        struct Commits: Decodable {
            struct CommitNode: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable { let state: String }
                    let statusCheckRollup: Rollup?
                }
                let commit: Commit
            }
            let nodes: [CommitNode?]?
        }

        let number: Int?
        let title: String?
        let url: String?
        let isDraft: Bool?
        let createdAt: Date?
        let updatedAt: Date?
        let reviewDecision: String?
        let mergeable: String?
        let repository: Repository?
        let commits: Commits?

        func toItem() -> PullRequestItem? {
            guard let number, let title, let url, let repo = repository?.nameWithOwner,
                  let createdAt, let updatedAt else { return nil }
            let lastCommit = commits?.nodes?.compactMap { $0 }.first
            return PullRequestItem(
                repo: repo, number: number, title: title, url: url,
                isDraft: isDraft ?? false,
                review: ReviewState(decision: reviewDecision),
                ci: CIState(rollup: lastCommit?.commit.statusCheckRollup?.state),
                hasConflicts: mergeable == "CONFLICTING",
                createdAt: createdAt, updatedAt: updatedAt
            )
        }
    }
    struct Data: Decodable { let search: Search? }

    let data: Data?
    let errors: [Failure]?
}
