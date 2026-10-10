import AppKit
import FocusCore
import SwiftUI

struct SearchHits {
    var tickets: [Ticket]
    var pullRequests: [PullRequestItem]

    var isEmpty: Bool { tickets.isEmpty && pullRequests.isEmpty }

    @MainActor
    static func find(_ query: String, in store: AppStore) -> SearchHits {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchHits(tickets: [], pullRequests: []) }
        let tickets = store.workspaceTickets.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.displayKey.localizedCaseInsensitiveContains(q)
                || ($0.github?.repo.localizedCaseInsensitiveContains(q) ?? false)
        }
        let pullRequests = store.workspacePullRequests.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.repo.localizedCaseInsensitiveContains(q)
                || "#\($0.number)".contains(q)
        }
        return SearchHits(
            tickets: Array(tickets.sorted { $0.updatedAt > $1.updatedAt }.prefix(8)),
            pullRequests: Array(pullRequests.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
        )
    }
}

/// The wide search field that lives in the window toolbar on every screen.
struct GlobalSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tickets and pull requests", text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit(onSubmit)
                .onExitCommand {
                    query = ""
                    focused.wrappedValue = false
                }
            if query.isEmpty {
                Text("⌘F").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
            } else {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
            }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(minWidth: 340, idealWidth: 480, maxWidth: 560)
        .background(Theme.cardBackground, in: shape)
        .overlay(shape.strokeBorder(focused.wrappedValue ? Theme.accent : Color.primary.opacity(0.14), lineWidth: focused.wrappedValue ? 1.5 : 1))
    }
}

/// Results card shown under the toolbar while a query is typed; clicking outside it dismisses.
struct SearchResultsOverlay: View {
    @Environment(AppStore.self) private var store
    let query: String
    let openTicket: (Ticket) -> Void
    let dismiss: () -> Void

    var body: some View {
        let hits = SearchHits.find(query, in: store)
        ZStack(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.001)).contentShape(Rectangle()).onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 4) {
                if hits.isEmpty {
                    Text("No results for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
                if !hits.tickets.isEmpty {
                    sectionTitle("Tickets")
                    ForEach(hits.tickets) { ticket in
                        ResultRow(symbol: ticket.status.symbol, tint: ticket.status.color, title: ticket.title, detail: ticket.displayKey) {
                            openTicket(ticket)
                        }
                    }
                }
                if !hits.pullRequests.isEmpty {
                    sectionTitle("Pull requests")
                    ForEach(hits.pullRequests) { item in
                        ResultRow(symbol: "arrow.triangle.pull", tint: Theme.accent, title: item.title, detail: "\(item.repo)#\(item.number)") {
                            if let url = URL(string: item.url), url.scheme == "https" { NSWorkspace.shared.open(url) }
                            dismiss()
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: 560)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.top, 8)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
    }
}

private struct ResultRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
