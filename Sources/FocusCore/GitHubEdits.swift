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
}
