import Foundation

private struct LabelDTO: Decodable { let name: String; let color: String? }
private struct MilestoneDTO: Decodable { let number: Int; let title: String; let state: String?; let dueOn: Date? }
private struct OrgFieldDTO: Decodable {
    struct Option: Decodable { let name: String; let color: String? }
    let id: Int
    let name: String
    let dataType: String
    let options: [Option]?
}

private struct IssueCommentDTO: Decodable {
    struct User: Decodable { let login: String }
    let id: Int
    let body: String?
    let htmlUrl: String
    let createdAt: Date
    let updatedAt: Date
    let user: User?
}

/// A comment on the GitHub issue, as shown read-only in the ticket detail.
public struct IssueComment: Identifiable, Equatable, Sendable {
    public var id: Int
    public var author: String
    public var body: String
    public var url: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int, author: String, body: String, url: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.author = author
        self.body = body
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension GitHubClient {
    /// All comments on the issue, oldest first. A deleted author shows as "ghost", as on GitHub.
    public func fetchComments(repo: String, number: Int) async throws -> [IssueComment] {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/issues/\(number)/comments?per_page=100") else { throw GitHubError.invalidResponse }
        return try await getAll(url, as: IssueCommentDTO.self).map {
            IssueComment(id: $0.id, author: $0.user?.login ?? "ghost", body: $0.body ?? "", url: $0.htmlUrl, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
    }
}

extension GitHubClient {
    private func getAll<T: Decodable>(_ url: URL, as type: T.Type, maxPages: Int = 20) async throws -> [T] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        var next: URL? = url
        var result: [T] = []
        var pages = 0
        while let current = next, pages < maxPages {
            let (data, response) = try await get(current)
            result += try decoder.decode([T].self, from: data)
            next = Self.nextURL(from: response.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return result
    }

    public func fetchLabels(repo: String) async throws -> [LabelOption] {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/labels?per_page=100") else { throw GitHubError.invalidResponse }
        return try await getAll(url, as: LabelDTO.self).map { LabelOption(name: $0.name, color: $0.color ?? "") }
    }

    public func fetchMilestones(repo: String) async throws -> [MilestoneOption] {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/milestones?state=all&per_page=100") else { throw GitHubError.invalidResponse }
        return try await getAll(url, as: MilestoneDTO.self).map {
            MilestoneOption(number: $0.number, title: $0.title, isOpen: $0.state != "closed", dueOn: $0.dueOn)
        }
    }

    /// Organization issue field definitions (Priority, Target date, ...). Fails with 404 for non-org owners.
    public func fetchOrgIssueFields(org: String) async throws -> [IssueFieldDefinition] {
        guard let url = URL(string: "https://\(Self.apiHost)/orgs/\(org)/issue-fields") else { throw GitHubError.invalidResponse }
        let (data, _) = try await get(url, apiVersion: Self.issueFieldsAPIVersion)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([OrgFieldDTO].self, from: data).map { dto in
            IssueFieldDefinition(id: dto.id, name: dto.name, dataType: dto.dataType, options: (dto.options ?? []).map { FieldOption(name: $0.name, color: $0.color) })
        }
    }

    /// Options of the single-select `field` (e.g. "Status") in each project the issue belongs to, keyed by project title.
    public func fetchProjectOptions(repo: String, number: Int, field: String) async throws -> [String: [FieldOption]] {
        var result: [String: [FieldOption]] = [:]
        for item in try await projectItems(repo: repo, number: number) {
            let node = (item.project.fields.nodes ?? []).compactMap { $0 }.first { $0.name == field }
            if let options = node?.options {
                result[item.project.title] = options.map { FieldOption(name: $0.name, color: $0.color?.lowercased()) }
            }
        }
        return result
    }

    private func issueURL(_ repo: String, _ number: Int, _ suffix: String = "") throws -> URL {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/issues/\(number)\(suffix)") else { throw GitHubError.invalidResponse }
        return url
    }

    private func send(method: String, _ url: URL, body: [String: Any]?, apiVersion: String = "2022-11-28") async throws -> Data {
        var request = request(for: url, apiVersion: apiVersion)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(request).0
    }

    /// Replaces all labels on the issue.
    public func setLabels(repo: String, number: Int, labels: [String]) async throws {
        _ = try await send(method: "PUT", issueURL(repo, number, "/labels"), body: ["labels": labels])
    }

    public func patchIssue(repo: String, number: Int, _ body: [String: Any]) async throws {
        _ = try await send(method: "PATCH", issueURL(repo, number), body: body)
    }

    /// Sets (or with nil clears) one organization issue field. GitHub's PUT replaces every value, so the others are re-sent.
    public func setIssueField(repo: String, number: Int, name: String, value: IssueFieldValue?) async throws {
        let valuesURL = try issueURL(repo, number, "/issue-field-values")
        let current = try await send(method: "GET", valuesURL, body: nil, apiVersion: Self.issueFieldsAPIVersion)
        let rows = (try JSONSerialization.jsonObject(with: current) as? [[String: Any]]) ?? []

        var entries: [[String: Any]] = []
        var targetID: Int?
        for row in rows {
            guard let id = row["issue_field_id"] as? Int else { continue }
            if (row["issue_field_name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame {
                targetID = id
                continue
            }
            let kept: Any?
            switch row["data_type"] as? String {
            case "single_select": kept = (row["single_select_option"] as? [String: Any])?["name"]
            case "multi_select": kept = (row["multi_select_options"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            default: kept = row["value"]
            }
            if let kept { entries.append(["field_id": id, "value": kept]) }
        }

        guard let value else {
            if let targetID {
                _ = try await send(method: "DELETE", valuesURL.appendingPathComponent(String(targetID)), body: nil, apiVersion: Self.issueFieldsAPIVersion)
            }
            return
        }

        if targetID == nil {
            guard let owner = repo.split(separator: "/").first else { throw GitHubError.invalidResponse }
            targetID = try await fetchOrgIssueFields(org: String(owner)).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        guard let targetID else { throw GitHubError.graphQL("The organization has no \"\(name)\" issue field.") }

        switch value {
        case .string(let text): entries.append(["field_id": targetID, "value": text])
        case .number(let number): entries.append(["field_id": targetID, "value": number])
        }
        _ = try await send(method: "PUT", valuesURL, body: ["issue_field_values": entries], apiVersion: Self.issueFieldsAPIVersion)
    }

    public func apply(_ edit: RemoteEdit, repo: String, number: Int) async throws {
        switch edit {
        case .labels(let labels):
            try await setLabels(repo: repo, number: number, labels: labels)
        case .milestone(let milestone):
            try await patchIssue(repo: repo, number: number, ["milestone": milestone.map { $0 as Any } ?? NSNull()])
        case .title(let title):
            try await patchIssue(repo: repo, number: number, ["title": title])
        case .body(let body):
            try await patchIssue(repo: repo, number: number, ["body": body])
        case .state(let open):
            try await patchIssue(repo: repo, number: number, open ? ["state": "open"] : ["state": "closed", "state_reason": "completed"])
        case .issueField(let name, let value):
            try await setIssueField(repo: repo, number: number, name: name, value: value)
        case .projectField(let project, let field, let value):
            try await updateProjectField(repo: repo, number: number, project: project, field: field, value: value)
        }
    }
}
