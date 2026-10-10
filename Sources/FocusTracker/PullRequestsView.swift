import FocusCore
import SwiftUI

struct PullRequestsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("pullRequestRepo") private var selectedRepo = ""

    private var loading: Bool { store.pullRequestsState == .loading }

    private var repoNames: [String] {
        Array(Set(store.workspacePullRequests.map(\.repo))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A saved repo that no longer has open PRs falls back to showing everything.
    private var activeRepo: String? {
        repoNames.contains(selectedRepo) ? selectedRepo : nil
    }

    private var sections: [PullRequestSection] {
        guard let repo = activeRepo else { return store.pullRequestSections }
        return PullRequestSection.make(from: store.workspacePullRequests.filter { $0.repo == repo })
    }

    var body: some View {
        let sections = self.sections
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: "Pull Requests", subtitle: subtitle)
                    Spacer()
                    Button { Task { await store.refreshPullRequests() } } label: {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.secondary)
                    .controlSize(.large)
                    .disabled(loading)
                    .help("Reload your open pull requests")
                }

                if repoNames.count > 1 { repoMenu }

                if case .failed(let message) = store.pullRequestsState {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                }
                if sections.isEmpty, case .loaded = store.pullRequestsState {
                    EmptyHint(text: "No open pull requests.", symbol: "arrow.triangle.pull")
                }

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: section.group.title, count: section.items.count)
                        VStack(spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                PullRequestRow(item: item)
                            }
                        }
                        .cardStyle(padding: 0)
                    }
                }

                if case .loaded(_, let total) = store.pullRequestsState, total > 100 {
                    Text("Showing the first 100 of \(total).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.pageBackground)
        .task { await store.refreshPullRequestsIfStale() }
    }

    private var repoMenu: some View {
        Menu {
            Picker("Repository", selection: $selectedRepo) {
                Text("All repositories").tag("")
                Divider()
                ForEach(repoNames, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            FilterLabel(title: activeRepo ?? "All repositories", symbol: "shippingbox", active: activeRepo != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var subtitle: String {
        switch store.pullRequestsState {
        case .loaded(let date, _): "Updated \(date.formatted(.relative(presentation: .named)))"
        case .loading: "Loading…"
        default: "Open pull requests you authored"
        }
    }
}

private struct PullRequestRow: View {
    let item: PullRequestItem

    private var destination: URL? {
        guard let url = URL(string: item.url), url.scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        if let destination {
            Link(destination: destination) { content }
                .buttonStyle(.plain)
                .help("Open on GitHub")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(item.repo)#\(item.number) · updated \(item.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            FlowLayout { chips }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var chips: some View {
        if item.isDraft {
            Chip(text: "Draft", color: Theme.slate, symbol: "pencil")
        } else {
            switch item.review {
            case .approved: Chip(text: "Approved", color: Theme.success, symbol: "checkmark.circle.fill")
            case .changesRequested: Chip(text: "Changes requested", color: Theme.danger, symbol: "xmark.circle.fill")
            case .waiting: Chip(text: "Waiting", color: Theme.warning, symbol: "clock")
            }
        }
        switch item.ci {
        case .passing: Chip(text: "Checks passing", color: Theme.success, symbol: "checkmark")
        case .failing: Chip(text: "Checks failing", color: Theme.danger, symbol: "xmark")
        case .pending: Chip(text: "Checks running", color: Theme.info, symbol: "circle.dotted")
        case .noChecks: EmptyView()
        }
        if item.hasConflicts {
            Chip(text: "Conflicts", color: Theme.danger, symbol: "exclamationmark.triangle.fill")
        }
    }
}
