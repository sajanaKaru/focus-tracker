import FocusCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(PrefKey.repos) private var repos = ""
    @AppStorage(PrefKey.includePRs) private var includePRs = false
    @AppStorage(PrefKey.syncMinutes) private var syncMinutes = 10
    @AppStorage(PrefKey.idleMinutes) private var idleMinutes = 10
    @AppStorage(PrefKey.workingMinutes) private var workingMinutes = 480
    @AppStorage(PrefKey.focusPercent) private var focusPercent = 75
    @AppStorage(PrefKey.defaultEstimateMinutes) private var defaultEstimateMinutes = 60

    @State private var token = ""
    @State private var hasToken = Keychain.get(account: Keychain.githubAccount) != nil
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("GitHub") {
                SecureField("Personal access token", text: $token)
                HStack {
                    Button("Save & Sync") { Task { await saveToken() } }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    if hasToken {
                        Button("Remove token", role: .destructive) {
                            Keychain.delete(account: Keychain.githubAccount)
                            hasToken = false
                            message = "Token removed."
                        }
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Needs read access to issues (classic token: `repo`, or fine-grained: Issues → Read). To show Sprint, Estimate, RCA and other Project fields, also add `read:project` (classic) or Projects → Read (fine-grained). To edit RCA and estimates from the app, use `project` (classic) or Projects → Read and write (fine-grained). Stored in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)

                TextField("Only these repos (owner/name, comma separated)", text: $repos)
                Toggle("Include assigned pull requests", isOn: $includePRs)
                Stepper("Auto-sync every \(syncMinutes) min", value: $syncMinutes, in: 1...120)
            }

            Section("Focus") {
                Stepper(idleMinutes == 0 ? "Idle auto-stop: off" : "Stop timer after \(idleMinutes) min idle", value: $idleMinutes, in: 0...60)
            }

            Section("Daily plan") {
                Stepper("Daily working time: \(Format.short(TimeInterval(workingMinutes * 60)))", value: $workingMinutes, in: 60...960, step: 30)
                Stepper("Focus factor: \(focusPercent)%", value: $focusPercent, in: 30...100, step: 5)
                Stepper("Default estimate: \(Format.short(TimeInterval(defaultEstimateMinutes * 60)))", value: $defaultEstimateMinutes, in: 15...480, step: 15)
                Text("Capacity = (working time − meetings) × focus factor. Tickets without an estimate count as the default estimate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }

    private func saveToken() async {
        busy = true
        defer { busy = false }
        let value = token.trimmingCharacters(in: .whitespaces)
        do {
            let login = try await GitHubClient(token: value).currentUser()
            try Keychain.set(value, account: Keychain.githubAccount)
            token = ""
            hasToken = true
            message = "Connected as @\(login)."
            await store.syncGitHub()
        } catch {
            message = error.localizedDescription
        }
    }
}
