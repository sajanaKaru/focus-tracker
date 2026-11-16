import Foundation

public enum Collapse {
    /// Long threads start collapsed so they don't push the rest of the ticket off screen.
    public static func commentsAreLong(_ bodies: [String]) -> Bool {
        bodies.count > 5 || bodies.reduce(0) { $0 + $1.count } > 2000
    }
}
