import Foundation

public enum Format {
    /// "01:05:09"
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "1h 05m", "12m", "0m"
    public static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes >= 60 { return String(format: "%dh %02dm", minutes / 60, minutes % 60) }
        return "\(minutes)m"
    }
}
