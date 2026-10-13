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

    /// Whether drafting sends the linked pull requests' code changes to the provider. Off by default.
    public var aiIncludeCode: Bool { defaults.bool(forKey: PrefKey.aiIncludeCode) }

    public func setAIIncludeCode(_ include: Bool) {
        defaults.set(include, forKey: PrefKey.aiIncludeCode)
    }

    /// Whether drafting also reads related files from the pull request's repository on GitHub. Off by default.
    public var aiScanGitHub: Bool { defaults.bool(forKey: PrefKey.aiScanGitHub) }

    public func setAIScanGitHub(_ enabled: Bool) {
        defaults.set(enabled, forKey: PrefKey.aiScanGitHub)
    }

    /// Whether Copilot may read a local checkout of the repository while drafting. Off by default; Copilot only.
    public var aiRepoAccess: Bool { defaults.bool(forKey: PrefKey.aiRepoAccess) }

    public func setAIRepoAccess(_ enabled: Bool) {
        defaults.set(enabled, forKey: PrefKey.aiRepoAccess)
    }

    /// Folder that holds the local checkouts, e.g. `~/Developer`.
    public var aiReposFolder: String { defaults.string(forKey: PrefKey.aiReposFolder) ?? "" }

    public func setAIReposFolder(_ folder: String) {
        defaults.set(folder.trimmingCharacters(in: .whitespacesAndNewlines), forKey: PrefKey.aiReposFolder)
    }

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
    public func draftTestCases(ticketID: UUID, pullRequests: [LinkedPullRequest], regression: Bool = false) async throws -> [DraftCase] {
        let provider = aiProvider
        let key = aiKey(for: provider)
        if provider.usesAPIKey, key == nil { throw AIError.missingKey(provider) }
        guard let ticket = ticket(ticketID) else { return [] }

        var details: [PullRequestDetail] = []
        var github: GitHubClient?
        if !pullRequests.isEmpty {
            guard let token = tokenProvider(), !token.isEmpty else { throw GitHubError.unauthorized }
            let client = GitHubClient(token: token, transport: transport)
            github = client
            for pr in pullRequests {
                var detail = try await client.fetchPullRequestDetail(repo: pr.repo, number: pr.number)
                if aiIncludeCode {
                    // Without patches the draft still works from titles and file names.
                    detail.patches = (try? await client.fetchPullRequestPatches(repo: pr.repo, number: pr.number)) ?? []
                    try Task.checkCancellation()
                }
                details.append(detail)
            }
        }
        let make = regression ? DraftPrompt.makeRegression : DraftPrompt.make
        var prompt = make(ticket.displayKey, ticket.title, ticket.body, details)

        var repository: URL?
        if provider == .copilot, aiRepoAccess, let repo = pullRequests.first?.repo ?? ticket.github?.repo {
            repository = RepoLocator.find(repo: repo, in: aiReposFolder)
            if repository == nil, !aiScanGitHub {
                notice = "No local checkout of \(repo) found in the repositories folder, so Copilot drafted without reading the code."
            }
        }
        if repository == nil, aiScanGitHub, let github, !details.isEmpty {
            prompt.user += try await scanRepositories(details: details, github: github, base: prompt, provider: provider, key: key)
        }

        let text = try await complete(prompt, provider: provider, key: key, repository: repository)
        let cases = try AICaseClient.parseCases(text, regression: prompt.regression)
        guard !cases.isEmpty else { throw AIError.noCases }
        return cases
    }

    private func complete(_ prompt: DraftPrompt, provider: AIProvider, key: String?, repository: URL? = nil) async throws -> String {
        if provider == .copilot {
            return try await copilotClient().complete(prompt, model: aiModel(for: provider), repository: repository)
        }
        return try await AICaseClient(provider: provider, model: aiModel(for: provider), apiKey: key ?? "", transport: transport).complete(prompt)
    }

    /// Reads related files from GitHub at each pull request's latest commit: the AI picks them from the file list, then their text is returned for the prompt.
    private func scanRepositories(details: [PullRequestDetail], github: GitHubClient, base: DraftPrompt, provider: AIProvider, key: String?) async throws -> String {
        var out = ""
        var budget = RepoScan.maxTotalChars
        for pr in details.prefix(3) where budget > 0 {
            do {
                let sha = try await github.fetchPullRequestHead(repo: pr.repo, number: pr.number)
                let paths = RepoScan.candidatePaths(try await github.fetchTreePaths(repo: pr.repo, sha: sha))
                guard !paths.isEmpty else { continue }
                let reply = try await complete(RepoScan.selectionPrompt(from: base, paths: paths), provider: provider, key: key)
                var files: [(path: String, text: String)] = []
                for path in RepoScan.parseSelection(reply, allowed: Set(paths)) where budget > 0 {
                    try Task.checkCancellation()
                    guard let text = try? await github.fetchFileText(repo: pr.repo, path: path, sha: sha, maxChars: min(RepoScan.maxFileChars, budget)) else { continue }
                    budget -= text.count
                    files.append((path, text))
                }
                out += RepoScan.section(repo: pr.repo, files: files)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notice = "Couldn't scan \(pr.repo) on GitHub (\(error.localizedDescription)); drafted without it."
            }
        }
        return out
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
        drafts.reduce(0) {
            $0 + (addTestCase(ticketID: ticketID, title: $1.title, steps: $1.steps, expected: $1.expected, risk: $1.risk, isRegression: $1.isRegression) == nil ? 0 : 1)
        }
    }
}
