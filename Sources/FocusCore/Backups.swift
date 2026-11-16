import Foundation

public struct BackupVersion: Identifiable, Equatable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let size: Int

    public var id: String { url.lastPathComponent }
}

/// Timestamped copies of the data file kept in one folder, newest first.
public struct BackupVault: Sendable {
    public static let prefix = "data-"
    public static let fileExtension = "json"

    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int = 30) {
        self.directory = directory
        self.keep = max(1, keep)
    }

    public func versions() -> [BackupVersion] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { url -> BackupVersion? in
            guard let date = Self.date(from: url.lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return BackupVersion(url: url, createdAt: date, size: size)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Copies `source` into the vault, then drops versions beyond `keep`. Returns nil when `source` doesn't exist.
    @discardableResult
    public func create(from source: URL, at date: Date = Date()) throws -> BackupVersion? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(Self.fileName(for: date))
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        for stale in versions().dropFirst(keep) { try? FileManager.default.removeItem(at: stale.url) }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return BackupVersion(url: target, createdAt: Self.date(from: target.lastPathComponent) ?? date, size: size)
    }

    public func export(_ version: BackupVersion, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: version.url, to: destination)
    }

    public func delete(_ version: BackupVersion) throws {
        try FileManager.default.removeItem(at: version.url)
    }

    /// Names carry the UTC time to the second, so ordering never depends on file attributes.
    static func fileName(for date: Date) -> String {
        "\(prefix)\(formatter.string(from: date)).\(fileExtension)"
    }

    static func date(from fileName: String) -> Date? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".\(fileExtension)") else { return nil }
        let stamp = fileName.dropFirst(prefix.count).dropLast(fileExtension.count + 1)
        return formatter.date(from: String(stamp))
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }
}
