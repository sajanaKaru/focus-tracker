import Foundation

/// How much code the AI may see when drafting. Each level includes the one before it.
public enum CodeAccess: String, CaseIterable, Identifiable, Sendable {
    case off, diffs, repository

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .diffs: "PR changes"
        case .repository: "PR changes + repository"
        }
    }

    public var sendsDiffs: Bool { self != .off }
    public var readsRepository: Bool { self == .repository }

    /// What is sent to the provider at this level; shown in Settings and in the draft sheet.
    public func disclosure(provider: AIProvider) -> String {
        let base = "The ticket text and the chosen pull requests' titles, descriptions and changed file names"
        switch self {
        case .off:
            return "\(base) are sent to \(provider.title). Source code is not sent."
        case .diffs:
            return "\(base), plus their code changes (diffs, up to about 24,000 characters), are sent to \(provider.title)."
        case .repository:
            return "\(base), plus their code changes (diffs) and up to \(RepoScan.maxFiles) related files read from the repository on GitHub "
                + "(about \(RepoScan.maxTotalChars.formatted()) characters at most), are sent to \(provider.title). "
                + "Lockfiles, generated files and secret files are skipped, but secrets written inside source files are not detected. Costs one extra AI request."
        }
    }
}
