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

    /// How much code drafting may send to the provider. Defaults to off; an older "send PR code changes" setting counts as `.diffs`.
    public var aiCodeAccess: CodeAccess {
        if let saved = defaults.string(forKey: PrefKey.aiCodeAccess).flatMap(CodeAccess.init(rawValue:)) { return saved }
        return defaults.bool(forKey: PrefKey.aiIncludeCode) ? .diffs : .off
    }

    public func setAICodeAccess(_ access: CodeAccess) {
        defaults.set(access.rawValue, forKey: PrefKey.aiCodeAccess)
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
        let access = aiCodeAccess
        draftNote = nil

        var details: [PullRequestDetail] = []
        var github: GitHubClient?
        if !pullRequests.isEmpty {
            guard let token = tokenProvider(), !token.isEmpty else { throw GitHubError.unauthorized }
            let client = GitHubClient(token: token, transport: transport)
            github = client
            for pr in pullRequests {
                var detail = try await client.fetchPullRequestDetail(repo: pr.repo, number: pr.number)
                if access.sendsDiffs {
                    // Without patches the draft still works from titles and file names.
                    detail.patches = (try? await client.fetchPullRequestPatches(repo: pr.repo, number: pr.number)) ?? []
                    try Task.checkCancellation()
                }
                details.append(detail)
            }
        }
        let make = regression ? DraftPrompt.makeRegression : DraftPrompt.make
        var prompt = make(ticket.displayKey, ticket.title, ticket.body, details)

        if access.readsRepository {
            if let github, !details.isEmpty {
                let scan = try await scanRepositories(details: details, ticket: ticket, github: github, provider: provider, key: key)
                prompt.user += scan.section
                draftNote = scan.summary
            } else {
                draftNote = "No linked pull request, so no repository files were read."
            }
        }

        let text = try await complete(prompt, provider: provider, key: key)
        let cases = try AICaseClient.parseCases(text, regression: prompt.regression)
        guard !cases.isEmpty else { throw AIError.noCases }
        return cases
    }

    private func complete(_ prompt: DraftPrompt, provider: AIProvider, key: String?) async throws -> String {
        if provider == .copilot {
            return try await copilotClient().complete(prompt, model: aiModel(for: provider))
        }
        return try await AICaseClient(provider: provider, model: aiModel(for: provider), apiKey: key ?? "", transport: transport).complete(prompt)
    }

    private struct RepoScanResult {
        var section = ""
        var files: [String] = []
        var problems: [String] = []

        var summary: String {
            var parts = [files.isEmpty ? "The AI picked no related files to read." : "Read \(files.count) related file\(files.count == 1 ? "" : "s") from GitHub: \(files.joined(separator: ", "))."]
            parts += problems
            return parts.joined(separator: " ")
        }
    }

    /// Reads related files from GitHub at each pull request's latest commit: the AI picks them from the file list, then their text is returned for the prompt.
    private func scanRepositories(details: [PullRequestDetail], ticket: Ticket, github: GitHubClient, provider: AIProvider, key: String?) async throws -> RepoScanResult {
        var result = RepoScanResult()
        var budget = RepoScan.maxTotalChars
        for pr in details.prefix(3) where budget > 0 {
            do {
                // Only this pull request's context, so several pull requests don't repeat each other's text.
                let base = DraftPrompt.make(ticketKey: ticket.displayKey, title: ticket.title, body: ticket.body, pullRequests: [pr])
                let sha = try await github.fetchPullRequestHead(repo: pr.repo, number: pr.number)
                let changed = pr.files + pr.patches.map(\.path)
                let paths = RepoScan.candidatePaths(try await github.fetchTreeFiles(repo: pr.repo, sha: sha), near: changed)
                guard !paths.isEmpty else {
                    result.problems.append("No readable files found in \(pr.repo).")
                    continue
                }
                let selection = RepoScan.selectionPrompt(from: base, repo: pr.repo, number: pr.number, paths: paths)
                let reply = try await complete(selection, provider: provider, key: key)
                var files: [(path: String, text: String)] = []
                for path in RepoScan.parseSelection(reply, allowed: Set(paths)) where budget > 0 {
                    try Task.checkCancellation()
                    guard let text = try? await github.fetchFileText(repo: pr.repo, path: path, sha: sha, maxChars: min(RepoScan.maxFileChars, budget)) else { continue }
                    budget -= text.count
                    files.append((path, text))
                }
                result.section += RepoScan.section(repo: pr.repo, files: files)
                result.files += files.map { "\(pr.repo)/\($0.path)" }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.problems.append("Couldn't scan \(pr.repo) on GitHub (\(error.localizedDescription)).")
            }
        }
        return result
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
