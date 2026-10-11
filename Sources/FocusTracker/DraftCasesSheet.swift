import FocusCore
import SwiftUI

struct DraftCasesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket

    private enum Phase { case loadingPRs, choosing, generating, review }

    @State private var phase = Phase.loadingPRs
    @State private var linked: [LinkedPullRequest] = []
    @State private var chosenPRs: Set<String> = []
    @State private var drafts: [DraftCase] = []
    @State private var kept: Set<UUID> = []
    @State private var error: String?

    var body: some View {
        Form {
            Section { Text("Draft test cases").font(.title2.weight(.bold)) }
            switch phase {
            case .loadingPRs:
                HStack { ProgressView().controlSize(.small); Text("Looking for linked pull requests…") }
            case .choosing: choosing
            case .generating:
                HStack { ProgressView().controlSize(.small); Text("Asking \(store.aiProvider.title)…") }
            case .review: review
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            actions
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .task { await loadPullRequests() }
    }

    @ViewBuilder private var choosing: some View {
        if linked.isEmpty {
            Text("No linked pull request found. Test cases will be drafted from the ticket text only.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(linked) { pr in
                Toggle(isOn: Binding(
                    get: { chosenPRs.contains(pr.id) },
                    set: { if $0 { chosenPRs.insert(pr.id) } else { chosenPRs.remove(pr.id) } }
                )) {
                    VStack(alignment: .leading) {
                        Text("#\(pr.number) \(pr.title)")
                        Text("\(pr.repo) · \(pr.state.capitalized)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Text("The ticket text, the chosen pull requests' titles, descriptions and changed file names are sent to \(store.aiProvider.title). Source code is not sent.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var review: some View {
        ForEach(drafts) { draft in
            Toggle(isOn: Binding(
                get: { kept.contains(draft.id) },
                set: { if $0 { kept.insert(draft.id) } else { kept.remove(draft.id) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title).fontWeight(.medium)
                    if !draft.steps.isEmpty { Text(draft.steps).font(.caption).foregroundStyle(.secondary) }
                    if !draft.expected.isEmpty { Text("Expected: \(draft.expected)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                .keyboardShortcut(.cancelAction)
            switch phase {
            case .choosing:
                Button { Task { await generate() } } label: { ShortcutLabel(title: error == nil ? "Draft" : "Retry", keys: "↩") }
                    .keyboardShortcut(.defaultAction)
            case .review:
                Button(action: add) { ShortcutLabel(title: "Add \(kept.count) selected", keys: "↩") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(kept.isEmpty)
            case .loadingPRs, .generating:
                EmptyView()
            }
        }
    }

    private func loadPullRequests() async {
        do {
            linked = try await store.linkedPullRequests(for: ticket.id)
            chosenPRs = Set(linked.filter { $0.state == "OPEN" || $0.state == "MERGED" }.map(\.id))
        } catch {
            self.error = "Couldn't load linked pull requests (\(error.localizedDescription)). You can still draft from the ticket text."
        }
        phase = .choosing
    }

    private func generate() async {
        error = nil
        phase = .generating
        do {
            drafts = try await store.draftTestCases(ticketID: ticket.id, pullRequests: linked.filter { chosenPRs.contains($0.id) })
            kept = Set(drafts.map(\.id))
            phase = .review
        } catch {
            self.error = error.localizedDescription
            phase = .choosing
        }
    }

    private func add() {
        store.addDrafts(ticketID: ticket.id, drafts.filter { kept.contains($0.id) })
        dismiss()
    }
}
