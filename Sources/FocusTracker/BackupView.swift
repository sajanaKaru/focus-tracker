import AppKit
import FocusCore
import SwiftUI

struct BackupView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(title: "Backup", subtitle: "Saved versions of your data. Download any version as a JSON file.")
                Spacer()
                Button { store.createBackup() } label: { Label("Back up now", systemImage: "externaldrive.badge.plus") }
                    .buttonStyle(.primary)
            }
            .padding(20)
            Divider()
            if store.backupVersions.isEmpty {
                ContentUnavailableView("No backups yet", systemImage: "externaldrive", description: Text("Back up now to save the first version."))
                    .frame(maxHeight: .infinity)
            } else {
                List(store.backupVersions) { version in
                    BackupRow(version: version) { download(version) }
                }
                .listStyle(.inset)
                Text("The latest 30 versions are kept; a new one is saved on launch when the last is over 6 hours old.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .background(Theme.pageBackground)
        .task { store.refreshBackups() }
    }

    private func download(_ version: BackupVersion) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "focus-tracker-\(version.url.deletingPathExtension().lastPathComponent.dropFirst(5)).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        store.exportBackup(version, to: destination)
    }
}

private struct BackupRow: View {
    @Environment(AppStore.self) private var store
    let version: BackupVersion
    let download: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "externaldrive", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(version.createdAt.formatted(date: .abbreviated, time: .standard)).font(.body.weight(.medium))
                Text(ByteCountFormatter.string(fromByteCount: Int64(version.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: download) { Label("Download", systemImage: "arrow.down.circle") }
                .buttonStyle(.secondary)
            DeleteButton(title: "Delete this backup?", help: "Delete version") { store.deleteBackup(version) }
        }
        .padding(.vertical, 4)
    }
}
