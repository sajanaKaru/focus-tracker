import FocusCore
import SwiftUI

/// Read-only GitHub comments on the issue, with a pointer to any unposted plan drafts.
struct TicketCommentsSection: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    var onPlan: () -> Void

    var body: some View {
        if ticket.github != nil {
            let comments = store.issueComments[ticket.id] ?? []
            let loading = store.commentsLoading.contains(ticket.id)
            let drafts = store.unpostedPlanComments(for: ticket.id)
            Section {
                if comments.isEmpty {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if let error = store.commentsError[ticket.id] {
                        Text("Couldn't load comments: \(error)").foregroundStyle(Theme.danger)
                    } else if store.issueComments[ticket.id] != nil {
                        Text("No comments on GitHub yet.").foregroundStyle(.secondary)
                    } else {
                        Text("Comments load from GitHub once a token is set in Settings.").foregroundStyle(.secondary)
                    }
                } else if let error = store.commentsError[ticket.id] {
                    Text("Showing earlier comments; refresh failed: \(error)").font(.caption).foregroundStyle(Theme.warning)
                }
                ForEach(comments) { CommentRow(comment: $0) }
                if !drafts.isEmpty {
                    Button(action: onPlan) {
                        Label("\(drafts.count) plan draft\(drafts.count == 1 ? "" : "s") not posted yet", systemImage: "square.and.pencil")
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Comments")
                    if !comments.isEmpty { Text("\(comments.count)").foregroundStyle(.secondary) }
                    Spacer()
                    if loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { Task { await store.loadComments(ticket.id, minimumInterval: 0) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Reload comments")
                            .accessibilityLabel("Reload comments")
                    }
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: IssueComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.author).font(.callout.weight(.semibold))
                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                if comment.updatedAt.timeIntervalSince(comment.createdAt) > 60 { Text("· edited").foregroundStyle(.tertiary) }
                Spacer()
                if let url = URL(string: comment.url), url.scheme == "https" {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help("Open on GitHub")
                }
            }
            .font(.caption)
            if comment.body.isEmpty {
                Text("No content").foregroundStyle(.secondary)
            } else {
                DescriptionView(markdown: comment.body)
            }
        }
        .padding(.vertical, 4)
    }
}
