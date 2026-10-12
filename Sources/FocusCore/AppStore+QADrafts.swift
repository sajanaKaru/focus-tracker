import Foundation

extension AppStore {
    public var aiProvider: AIProvider {
        defaults.string(forKey: PrefKey.aiProvider).flatMap(AIProvider.init(rawValue:)) ?? .openAI
    }

    public func setAIProvider(_ provider: AIProvider) {
        defaults.set(provider.rawValue, forKey: PrefKey.aiProvider)
    }

    public func aiModel(for provider: AIProvider) -> String {
        let saved = defaults.string(forKey: PrefKey.aiModelPrefix + provider.rawValue)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }

    public func setAIModel(_ model: String, for provider: AIProvider) {
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: PrefKey.aiModelPrefix + provider.rawValue)
    }

    /// Copilot has no key to check; a missing or signed-out CLI is reported when drafting.
    public var hasAIKey: Bool { !aiProvider.usesAPIKey || aiKey(for: aiProvider) != nil }

    private func aiKey(for provider: AIProvider) -> String? {
        guard let key = aiKeyProvider(provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// Pull requests that reference the ticket's issue; empty for local tickets.
    public func linkedPullRequests(for ticketID: UUID) async throws -> [LinkedPullRequest] {
        guard let gh = ticket(ticketID)?.github, !gh.isPullRequest else { return [] }
        guard let token = tokenProvider(), !token.isEmpty else { throw GitHubError.unauthorized }
        return try await GitHubClient(token: token, transport: transport).fetchLinkedPullRequests(repo: gh.repo, number: gh.number)
    }

    /// Asks the configured AI provider for draft cases. Nothing is saved; see `addDrafts`.
    public func draftTestCases(ticketID: UUID, pullRequests: [LinkedPullRequest]) async throws -> [DraftCase] {
        let provider = aiProvider
        let key = aiKey(for: provider)
        if provider.usesAPIKey, key == nil { throw AIError.missingKey(provider) }
        guard let ticket = ticket(ticketID) else { return [] }

        var details: [PullRequestDetail] = []
        if !pullRequests.isEmpty {
            guard let token = tokenProvider(), !token.isEmpty else { throw GitHubError.unauthorized }
            let github = GitHubClient(token: token, transport: transport)
            for pr in pullRequests {
                details.append(try await github.fetchPullRequestDetail(repo: pr.repo, number: pr.number))
            }
        }
        let prompt = DraftPrompt.make(ticketKey: ticket.displayKey, title: ticket.title, body: ticket.body, pullRequests: details)
        if provider == .copilot {
            return try await copilotClient().draftCases(prompt, model: aiModel(for: provider))
        }
        let client = AICaseClient(provider: provider, model: aiModel(for: provider), apiKey: key ?? "", transport: transport)
        return try await client.draftCases(prompt)
    }

    /// Models enabled for the signed-in Copilot account.
    public func copilotModels() async throws -> [CopilotModel] {
        try await copilotClient().availableModels()
    }

    private func copilotClient() async throws -> CopilotACPClient {
        if let copilotChannel { return CopilotACPClient(open: copilotChannel) }
        guard let executable = await CopilotLocator.locate(override: defaults.string(forKey: PrefKey.copilotPath)) else {
            throw AIError.copilotNotInstalled
        }
        return CopilotACPClient(open: { try ProcessACPChannel(executable: executable, directory: $0) })
    }

    /// Saves the chosen drafts as test cases; returns how many were added.
    @discardableResult
    public func addDrafts(ticketID: UUID, _ drafts: [DraftCase]) -> Int {
        drafts.reduce(0) { $0 + (addTestCase(ticketID: ticketID, title: $1.title, steps: $1.steps, expected: $1.expected) == nil ? 0 : 1) }
    }
}
