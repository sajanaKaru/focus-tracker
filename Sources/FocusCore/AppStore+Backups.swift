import Foundation

extension AppStore {
    /// Skip the automatic launch backup when the newest version is younger than this.
    static let backupInterval: TimeInterval = 6 * 3600

    public func refreshBackups() {
        backupVersions = backupVault.versions()
    }

    /// Saves current data first so the version reflects what is on screen.
    @discardableResult
    public func createBackup() -> BackupVersion? {
        save()
        do {
            let version = try backupVault.create(from: storeURL)
            refreshBackups()
            return version
        } catch {
            notice = "Could not create backup: \(error.localizedDescription)"
            return nil
        }
    }

    public func backUpIfDue(now: Date = Date()) {
        refreshBackups()
        if let latest = backupVersions.first, now.timeIntervalSince(latest.createdAt) < Self.backupInterval { return }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            try backupVault.create(from: storeURL, at: now)
        } catch {
            notice = "Could not create backup: \(error.localizedDescription)"
        }
        refreshBackups()
    }

    @discardableResult
    public func exportBackup(_ version: BackupVersion, to destination: URL) -> Bool {
        do {
            try backupVault.export(version, to: destination)
            return true
        } catch {
            notice = "Could not save backup: \(error.localizedDescription)"
            return false
        }
    }

    public func deleteBackup(_ version: BackupVersion) {
        do {
            try backupVault.delete(version)
        } catch {
            notice = "Could not delete backup: \(error.localizedDescription)"
        }
        refreshBackups()
    }
}
