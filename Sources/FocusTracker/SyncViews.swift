import FocusCore
import SwiftUI

struct SyncBadge: View {
    let sync: ActionSync

    var body: some View {
        switch sync {
        case .notApplicable: EmptyView()
        case .pending: Chip(text: "Pending", color: Theme.warning, symbol: "arrow.triangle.2.circlepath")
        case .synced: Chip(text: "Synced", color: Theme.success, symbol: "checkmark.circle.fill")
        case .failed: Chip(text: "Failed", color: Theme.danger, symbol: "exclamationmark.triangle.fill")
        }
    }
}

/// Shows on a ticket whose last change hasn't reached GitHub yet.
struct TicketSyncMarker: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID

    var body: some View {
        switch store.syncStatus(for: ticketID) {
        case .synced: EmptyView()
        case .syncing: Chip(text: "Syncing", color: Theme.warning, symbol: "arrow.triangle.2.circlepath")
        case .failed: Chip(text: "Not synced", color: Theme.danger, symbol: "exclamationmark.triangle.fill")
        }
    }
}

struct FailureBanner: View {
    @Environment(AppStore.self) private var store
    @State private var resyncing = false

    var body: some View {
        let count = store.failureBannerCount
        if count > 0 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(count == 1 ? "1 change failed to sync to GitHub" : "\(count) changes failed to sync to GitHub")
                    .font(.callout.weight(.medium))
                Spacer()
                Button {
                    resyncing = true
                    Task {
                        await store.resyncFailed()
                        resyncing = false
                    }
                } label: {
                    if resyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Resync", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.secondary)
                .disabled(resyncing)
                Button("Dismiss") { store.dismissFailureBanner() }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.danger.opacity(0.12))
        }
    }
}

/// Today-page list of every change that failed to reach GitHub, with per-row Retry.
struct SyncIssuesCard: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @State private var retrying: Set<UUID> = []
    @State private var resyncingAll = false

    var body: some View {
        let failed = store.failedActions
        if !failed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Sync issues", count: failed.count)
                    Spacer()
                    Button {
                        resyncingAll = true
                        Task {
                            await store.resyncFailed()
                            resyncingAll = false
                        }
                    } label: {
                        if resyncingAll { ProgressView().controlSize(.small) } else { Label("Resync all", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .buttonStyle(.secondary)
                    .disabled(resyncingAll)
                }
                VStack(spacing: 0) {
                    ForEach(Array(failed.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        row(entry)
                    }
                }
                .cardStyle(padding: 0)
            }
        }
    }

    private func row(_ entry: ActionLogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.ticketTitle ?? entry.ticketKey ?? "Ticket").font(.body.weight(.medium)).lineLimit(1)
                Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let message = entry.sync.errorMessage {
                    Text(message).font(.caption).foregroundStyle(Theme.danger).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if let id = entry.ticketID, store.ticket(id) != nil {
                Button("Open") { selectedTicketID = id }.buttonStyle(.borderless)
            }
            Button {
                retrying.insert(entry.id)
                Task {
                    await store.retry(entry.id)
                    retrying.remove(entry.id)
                }
            } label: {
                if retrying.contains(entry.id) { ProgressView().controlSize(.small) } else { Text("Retry") }
            }
            .buttonStyle(.secondary)
            .disabled(retrying.contains(entry.id))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
