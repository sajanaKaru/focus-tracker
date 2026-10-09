import Foundation

public enum DescriptionBlock: Equatable, Sendable {
    case text(String)
    case image(url: String, alt: String)

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// Splits an issue body into text and image blocks (Markdown `![]()` and HTML `<img>`).
public enum DescriptionParser {
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)|<img\b[^>]*>"#,
        options: .caseInsensitive
    )
    private static let srcPattern = try! NSRegularExpression(pattern: #"\bsrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
    private static let altPattern = try! NSRegularExpression(pattern: #"\balt\s*=\s*["']([^"']*)["']"#, options: .caseInsensitive)

    public static func blocks(from markdown: String) -> [DescriptionBlock] {
        let ns = markdown as NSString
        var blocks: [DescriptionBlock] = []
        var cursor = 0

        func appendText(upTo end: Int) {
            guard end > cursor else { return }
            let text = ns.substring(with: NSRange(location: cursor, length: end - cursor))
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(text)) }
        }

        for match in imagePattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            guard let image = image(from: match, in: ns) else { continue }
            appendText(upTo: match.range.location)
            blocks.append(.image(url: image.url, alt: image.alt))
            cursor = match.range.location + match.range.length
        }
        appendText(upTo: ns.length)
        return blocks
    }

    public static func imageURLs(fromHTML html: String) -> [String] {
        blocks(from: html).compactMap { block in
            if case .image(let url, _) = block { return url }
            return nil
        }
    }

    private static func image(from match: NSTextCheckingResult, in ns: NSString) -> (url: String, alt: String)? {
        if match.range(at: 2).location != NSNotFound {
            return (clean(ns.substring(with: match.range(at: 2))), ns.substring(with: match.range(at: 1)))
        }
        let tag = ns.substring(with: match.range)
        guard let src = firstCapture(srcPattern, in: tag) else { return nil }
        return (clean(src), firstCapture(altPattern, in: tag) ?? "")
    }

    private static func firstCapture(_ regex: NSRegularExpression, in string: String) -> String? {
        let ns = string as NSString
        guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func clean(_ url: String) -> String {
        url.replacingOccurrences(of: "&amp;", with: "&")
    }
}
