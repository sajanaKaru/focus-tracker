import XCTest
@testable import FocusCore

@MainActor
final class BackupTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> AppStore {
        AppStore(
            storeURL: dir.appendingPathComponent("data.json"),
            defaults: UserDefaults(suiteName: "backup-\(UUID().uuidString)")!,
            tokenProvider: { nil },
            idleSeconds: { 0 },
            aiKeyProvider: { _ in nil }
        )
    }

    func testVaultListsNewestFirstAndKeepsLimit() throws {
        let source = dir.appendingPathComponent("source.json")
        try Data("{}".utf8).write(to: source)
        let vault = BackupVault(directory: dir.appendingPathComponent("v"), keep: 2)
        for offset in 0..<3 { try vault.create(from: source, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 60)) }
        let versions = vault.versions()
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.map(\.createdAt), [Date(timeIntervalSince1970: 1_700_000_120), Date(timeIntervalSince1970: 1_700_000_060)])
    }

    func testVaultIgnoresForeignFilesAndMissingSource() throws {
        let vault = BackupVault(directory: dir)
        XCTAssertNil(try vault.create(from: dir.appendingPathComponent("missing.json")))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        XCTAssertTrue(vault.versions().isEmpty)
    }

    func testExportCopiesVersionAndReplacesExistingFile() throws {
        let source = dir.appendingPathComponent("source.json")
        try Data("one".utf8).write(to: source)
        let vault = BackupVault(directory: dir.appendingPathComponent("v"))
        let version = try XCTUnwrap(try vault.create(from: source))
        let destination = dir.appendingPathComponent("out.json")
        try Data("old".utf8).write(to: destination)
        try vault.export(version, to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "one")
    }

    func testStoreCreatesAndDeletesBackups() throws {
        let store = makeStore()
        let version = try XCTUnwrap(store.createBackup())
        XCTAssertEqual(store.backupVersions.map(\.id), [version.id])
        store.deleteBackup(version)
        XCTAssertTrue(store.backupVersions.isEmpty)
    }

    func testRestoreReplacesDataAndKeepsSafetyBackup() throws {
        let store = makeStore()
        store.addTicket(title: "Before")
        let version = try XCTUnwrap(store.createBackup())
        store.addTicket(title: "After")
        XCTAssertEqual(store.tickets.count, 2)
        XCTAssertTrue(store.restore(from: version.url))
        XCTAssertEqual(store.tickets.map(\.title), ["Before"])
        XCTAssertGreaterThanOrEqual(store.backupVersions.count, 1)
    }

    func testRestoreRejectsInvalidFileAndKeepsData() throws {
        let store = makeStore()
        store.addTicket(title: "Keep")
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{\"nope\":1}".utf8).write(to: bad)
        XCTAssertFalse(store.restore(from: bad))
        XCTAssertEqual(store.tickets.map(\.title), ["Keep"])
    }

    func testAutomaticBackupSkippedWhenRecent() throws {
        let store = makeStore()
        store.save()
        let now = Date()
        store.backUpIfDue(now: now)
        XCTAssertEqual(store.backupVersions.count, 1)
        store.backUpIfDue(now: now.addingTimeInterval(3600))
        XCTAssertEqual(store.backupVersions.count, 1)
        store.backUpIfDue(now: now.addingTimeInterval(7 * 3600))
        XCTAssertEqual(store.backupVersions.count, 2)
    }
}
