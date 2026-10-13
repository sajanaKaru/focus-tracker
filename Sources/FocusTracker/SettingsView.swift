import FocusCore
import SwiftUI

struct SettingsView: View {
    private enum Field { case token, repos, aiKey }

    @Environment(AppStore.self) private var store
    @Environment(LicenseStore.self) private var license
    @AppStorage(PrefKey.repos) private var repos = ""
    @AppStorage(PrefKey.includePRs) private var includePRs = false
    @AppStorage(PrefKey.syncMinutes) private var syncMinutes = 10
    @AppStorage(PrefKey.idleMinutes) private var idleMinutes = 10
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.defaultEstimateMinutes) private var defaultEstimateMinutes = 60
    @AppStorage(PrefKey.workDays) private var workDays = 5
    @AppStorage(PrefKey.aiProvider) private var aiProviderRaw = AIProvider.openAI.rawValue
    @AppStorage(PrefKey.copilotPath) private var copilotPath = ""
    @AppStorage(PrefKey.aiIncludeCode) private var aiIncludeCode = false
    @AppStorage(PrefKey.aiRepoAccess) private var aiRepoAccess = false
    @AppStorage(PrefKey.aiScanGitHub) private var aiScanGitHub = false
    @AppStorage(PrefKey.aiReposFolder) private var aiReposFolder = ""

    @FocusState private var focus: Field?

    @State private var reposDraft = ""
    @State private var aiKey = ""
    @State private var aiModel = ""
    @State private var aiHasKey = false
    @State private var aiMessage: String?
    @State private var copilotModels: [CopilotModel] = []
    @State private var copilotStatus: String?
    @State private var copilotLoading = false

    @State private var token = ""
    @State private var hasToken = Keychain.get(account: Keychain.githubAccount) != nil
    @State private var message: String?
    @State private var busy = false
    @State private var confirmingRemoval = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            githubTab.tabItem { Label("GitHub", systemImage: "arrow.triangle.2.circlepath") }
            aiTab.tabItem { Label("AI", systemImage: "sparkles") }
            planningTab.tabItem { Label("Planning", systemImage: "calendar") }
        }
        .controlSize(.large)
        .frame(width: 640, height: 580)
        .onAppear { reposDraft = repos }
        .onChange(of: focus) { old, _ in
            switch old {
            case .token: commitToken()
            case .repos: commitRepos()
            case .aiKey: saveAIKey()
            case nil: break
            }
        }
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            if let email = license.email {
                Section("Account") {
                    LabeledContent("Signed in as", value: email)
                    Button("Sign out") { license.signOut() }.buttonStyle(.secondary)
                }
            }

            Section("Role") {
                Picker("Role", selection: Binding(get: { store.role }, set: { store.role = $0 })) {
                    ForEach(UserRole.allCases) { Text($0.title).tag($0) }
                }
                Text("Sets which tabs, status order and defaults the app shows. Applies immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Focus") {
                Stepper(idleMinutes == 0 ? "Idle auto-stop: off" : "Stop timer after \(idleMinutes) min idle", value: $idleMinutes, in: 0...60)
                Text("The timer stops when you have been away this long, and the idle time is not counted. Set 0 to turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: GitHub

    private var githubTab: some View {
        Form {
            Section("Connection") {
                SecureField("Personal access token", text: $token)
                    .focused($focus, equals: .token)
                    .onSubmit { commitToken() }
                HStack(spacing: 8) {
                    if busy {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").foregroundStyle(.secondary)
                    } else if let message {
                        Text(message).foregroundStyle(.secondary)
                    } else if hasToken {
                        Label("Token saved in the Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    } else {
                        Text("Paste a token and press Return to connect.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasToken {
                        Button("Remove token", role: .destructive) { confirmingRemoval = true }
                            .buttonStyle(.secondary)
                            .confirmDestructive(
                                $confirmingRemoval, title: "Remove the GitHub token?",
                                message: "Syncing stops until you add a token again.", confirmLabel: "Remove"
                            ) {
                                Keychain.delete(account: Keychain.githubAccount)
                                hasToken = false
                                message = "Token removed."
                            }
                    }
                }
                .font(.callout)
                Text("Needs read access to issues (classic token: `repo`, or fine-grained: Issues → Read). To show Sprint, Estimate, RCA and other Project fields, also add `read:project` (classic) or Projects → Read (fine-grained). To edit RCA and estimates from the app, use `project` (classic) or Projects → Read and write (fine-grained).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sync") {
                TextField("Only these repos", text: $reposDraft, prompt: Text("owner/name, comma separated"))
                    .focused($focus, equals: .repos)
                    .onSubmit { commitRepos() }
                Toggle("Include assigned pull requests", isOn: $includePRs)
                    .onChange(of: includePRs) { syncIfConnected() }
                Stepper("Auto-sync every \(syncMinutes) min", value: $syncMinutes, in: 1...120)
                    .onChange(of: syncMinutes) { store.restartAutoSync() }
                Text("Leave repos empty to sync every repo you can see. Changes sync right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Workspaces") {
                if store.knownWorkspaces.isEmpty {
                    Text("Connect GitHub and sync to list your personal and organization workspaces.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.knownWorkspaces, id: \.self) { workspace in
                    Toggle(workspace.title, isOn: Binding(
                        get: { store.isWorkspaceVisible(workspace) },
                        set: { store.setWorkspace(workspace, visible: $0) }
                    ))
                }
                Text("Choose which workspaces appear in the switcher. Turned-off workspaces are hidden everywhere, including All.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func commitToken() {
        guard !busy, !token.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await saveToken() }
    }

    private func commitRepos() {
        let value = reposDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        reposDraft = value
        guard value != repos else { return }
        repos = value
        syncIfConnected()
    }

    private func syncIfConnected() {
        guard hasToken else { return }
        Task { await store.syncGitHub() }
    }

    private func saveToken() async {
        busy = true
        message = nil
        defer { busy = false }
        let value = token.trimmingCharacters(in: .whitespaces)
        do {
            let login = try await GitHubClient(token: value).currentUser()
            store.setGitHubLogin(login)
            try Keychain.set(value, account: Keychain.githubAccount)
            token = ""
            hasToken = true
            message = "Connected as @\(login)."
            await store.syncGitHub()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: AI

    private var aiProvider: AIProvider { AIProvider(rawValue: aiProviderRaw) ?? .openAI }

    private var aiTab: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $aiProviderRaw) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: aiProviderRaw) { loadAI() }
                if aiProvider == .copilot {
                    copilotModelPicker
                } else {
                    TextField("Model", text: $aiModel, prompt: Text(aiProvider.defaultModel))
                        .onChange(of: aiModel) { store.setAIModel(aiModel, for: aiProvider) }
                    Text("Leave the model empty to use \(aiProvider.defaultModel).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if aiProvider == .copilot {
                copilotSection
            } else {
                Section("API key") {
                    SecureField("\(aiProvider.title) API key", text: $aiKey)
                        .focused($focus, equals: .aiKey)
                        .onSubmit { saveAIKey() }
                    HStack(spacing: 8) {
                        if let aiMessage {
                            Text(aiMessage).foregroundStyle(.secondary)
                        } else if aiHasKey {
                            Label("Key saved in the Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        } else {
                            Text("Paste a key and press Return to save it.").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if aiHasKey {
                            Button("Remove key", role: .destructive) {
                                Keychain.delete(account: aiProvider.keychainAccount)
                                aiHasKey = false
                                aiMessage = "Key removed."
                            }
                            .buttonStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    Text("Drafting sends the ticket text and linked pull requests' titles, descriptions and changed file names to the selected provider. Keys are stored in the macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Code context") {
                Toggle("Send PR code changes", isOn: $aiIncludeCode)
                Text("Adds the code changes (diffs) of linked pull requests to the prompt so cases match what actually changed. Up to about 24,000 characters; lockfiles, generated files and images are skipped. They are sent to \(aiProvider.title) along with the ticket text. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Scan the GitHub repository", isOn: $aiScanGitHub)
                Text("Reads related files straight from GitHub, with no local checkout: the AI picks up to 8 files (callers, helpers, tests) from the repository's file list, and their text, about 30,000 characters at most, is added to the prompt and sent to \(aiProvider.title). Uses the pull request's latest commit, skips lockfiles, generated files and secrets, and costs one extra AI request. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadAI() }
    }

    private var copilotModelPicker: some View {
        Picker("Model", selection: $aiModel) {
            Text("Auto").tag("")
            if !aiModel.isEmpty, !copilotModels.isEmpty, !copilotModels.contains(where: { $0.id == aiModel }) {
                Text("\(aiModel) (not enabled)").tag(aiModel)
            }
            ForEach(copilotModels.filter { $0.id != "auto" }) { Text($0.label).tag($0.id) }
        }
        .onChange(of: aiModel) { store.setAIModel(aiModel, for: aiProvider) }
    }

    private var copilotSection: some View {
        Section("GitHub Copilot") {
            TextField("CLI path", text: $copilotPath, prompt: Text("Detected automatically"))
            HStack(spacing: 8) {
                Button("Refresh models") { Task { await loadCopilotModels() } }
                    .buttonStyle(.secondary)
                    .disabled(copilotLoading)
                if copilotLoading { ProgressView().controlSize(.small) }
                if let copilotStatus { Text(copilotStatus).foregroundStyle(.secondary) }
            }
            .font(.callout)
            Text("Uses the models enabled for your Copilot account through the Copilot CLI. Sign in once with `copilot login` in a terminal; the GitHub token saved in this app is not used. Drafting sends the ticket text and linked pull requests' titles, descriptions and changed file names to GitHub Copilot.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Let Copilot read local repositories", isOn: $aiRepoAccess)
            if aiRepoAccess {
                HStack {
                    TextField("Repositories folder", text: $aiReposFolder, prompt: Text("e.g. ~/Developer"))
                    Button("Choose…") { chooseReposFolder() }.buttonStyle(.secondary)
                }
            }
            Text("Copilot works inside the local checkout of the pull request's repository (<folder>/<repo> or <folder>/<owner>/<repo>) and can read its files to find callers and related code. Reads are read-only, limited to that checkout, and skip .git, .env and key files; every other action is refused. Files it reads are sent to GitHub Copilot. The checkout may not be on the pull request's branch. Off by default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseReposFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { aiReposFolder = url.path }
    }

    private func loadAI() {
        aiModel = store.aiModel(for: aiProvider) == aiProvider.defaultModel ? "" : store.aiModel(for: aiProvider)
        aiHasKey = aiProvider.usesAPIKey && Keychain.get(account: aiProvider.keychainAccount) != nil
        aiKey = ""
        aiMessage = nil
        if aiProvider == .copilot { Task { await loadCopilotModels() } }
    }

    private func loadCopilotModels() async {
        copilotLoading = true
        copilotStatus = nil
        defer { copilotLoading = false }
        do {
            copilotModels = try await store.copilotModels()
            copilotStatus = "\(copilotModels.filter { $0.id != "auto" }.count) models enabled"
        } catch {
            copilotStatus = error.localizedDescription
        }
    }

    private func saveAIKey() {
        let value = aiKey.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        do {
            try Keychain.set(value, account: aiProvider.keychainAccount)
            aiKey = ""
            aiHasKey = true
            aiMessage = "Saved."
        } catch {
            aiMessage = error.localizedDescription
        }
    }

    // MARK: Planning

    private var planningTab: some View {
        Form {
            Section("Daily plan") {
                Picker("Working days", selection: $workDays) {
                    Text("Weekdays (Mon–Fri)").tag(5)
                    Text("6 days (Mon–Sat)").tag(6)
                    Text("7 days").tag(7)
                }
                Stepper("Daily working time: \(Format.short(TimeInterval(workingMinutes * 60)))", value: $workingMinutes, in: 60...960, step: 30)
                Stepper("Focus factor: \(focusPercent)%", value: $focusPercent, in: 30...100, step: 5)
                Stepper("Default estimate: \(Format.short(TimeInterval(defaultEstimateMinutes * 60)))", value: $defaultEstimateMinutes, in: 15...480, step: 15)
            }

            Section {
                Text("Capacity = (working time − meetings) × focus factor. Tickets without an estimate count as the default estimate. Days off have no capacity and are skipped when planning tomorrow. Changes apply to the plan immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
