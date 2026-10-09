import Foundation

/// A single replacement in a text buffer; `selection` is the selection to restore afterwards (UTF-16 offsets).
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

public enum MarkdownAction: Equatable, Sendable {
    case bold, italic, strikethrough, code, link
    case heading(Int), bullet, numbered, checkbox, quote, codeBlock
    case indent, outdent
}

/// Pure Markdown editing rules used by the comment editor's toolbar and key handling.
public enum MarkdownFormatter {
    enum Kind: Equatable {
        case none, heading(Int), bullet, numbered, checkbox, quote

        var isList: Bool { self == .bullet || self == .numbered || self == .checkbox }
    }

    struct Line {
        var indent: String
        var marker: String
        var kind: Kind
        var rest: String

        var prefixLength: Int { indent.utf16.count + marker.utf16.count }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^([ \t]*)(#{1,6} |[-*+] \[[ xX]\] |[-*+] |\d+\. |> )?(.*)$"#)

    static func parse(_ text: String) -> Line {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return Line(indent: "", marker: "", kind: .none, rest: text)
        }
        func group(_ i: Int) -> String {
            let r = match.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        let marker = group(2)
        let kind: Kind
        if marker.hasPrefix("#") {
            kind = .heading(marker.count - 1)
        } else if marker.hasPrefix(">") {
            kind = .quote
        } else if marker.contains("[") {
            kind = .checkbox
        } else if marker.first?.isNumber == true {
            kind = .numbered
        } else if marker.isEmpty {
            kind = .none
        } else {
            kind = .bullet
        }
        return Line(indent: group(1), marker: marker, kind: kind, rest: group(3))
    }

    public static func edit(_ action: MarkdownAction, in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let sel = clamp(selection, to: ns.length)
        switch action {
        case .bold: return wrap("**", in: ns, sel)
        case .italic: return wrap("_", in: ns, sel)
        case .strikethrough: return wrap("~~", in: ns, sel)
        case .code: return wrap("`", in: ns, sel)
        case .link: return link(in: ns, sel)
        case .heading(let level): return transform(.heading(max(1, min(6, level))), in: ns, sel)
        case .bullet: return transform(.bullet, in: ns, sel)
        case .numbered: return transform(.numbered, in: ns, sel)
        case .checkbox: return transform(.checkbox, in: ns, sel)
        case .quote: return transform(.quote, in: ns, sel)
        case .codeBlock: return codeBlock(in: ns, sel)
        case .indent: return indent(in: text, selection: sel, outdent: false, onlyLists: false)
        case .outdent: return indent(in: text, selection: sel, outdent: true, onlyLists: false)
        }
    }

    /// Continues a list, task list or quote on Return; an empty item ends the list. Nil means "use the default behavior".
    public static func newline(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        let sel = clamp(selection, to: ns.length)
        guard sel.length == 0 else { return nil }

        let lineRange = ns.lineRange(for: sel)
        let line = parse(trimmingNewline(ns.substring(with: lineRange)))
        guard line.kind == .quote || line.kind.isList, sel.location >= lineRange.location + line.prefixLength else { return nil }

        if line.rest.trimmingCharacters(in: .whitespaces).isEmpty {
            let content = NSRange(location: lineRange.location, length: line.prefixLength + line.rest.utf16.count)
            return TextEdit(range: content, replacement: "", selection: NSRange(location: lineRange.location, length: 0))
        }

        let next: String
        switch line.kind {
        case .numbered: next = "\((Int(line.marker.dropLast(2)) ?? 0) + 1). "
        case .checkbox: next = "\(line.marker.first ?? "-") [ ] "
        default: next = line.marker
        }
        let insert = "\n" + line.indent + next
        return TextEdit(range: sel, replacement: insert, selection: NSRange(location: sel.location + insert.utf16.count, length: 0))
    }

    /// Indents or outdents the selected lines; nested items need 3 spaces under a numbered item and 2 otherwise.
    public static func indent(in text: String, selection: NSRange, outdent: Bool, onlyLists: Bool) -> TextEdit? {
        let ns = text as NSString
        let sel = clamp(selection, to: ns.length)
        let block = lineBlock(in: ns, sel)
        let parsed = block.lines.map(parse)
        if onlyLists, !parsed.contains(where: { $0.kind.isList }) { return nil }

        var lines = block.lines
        for i in lines.indices where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
            let width = parsed[i].kind == .numbered ? 3 : 2
            if !outdent {
                lines[i] = String(repeating: " ", count: width) + lines[i]
            } else if lines[i].hasPrefix("\t") {
                lines[i].removeFirst()
            } else {
                lines[i].removeFirst(min(width, lines[i].prefix { $0 == " " }.count))
            }
        }
        guard lines != block.lines else { return nil }
        return blockEdit(block, lines: lines, sel, caretShift: lines[0].utf16.count - block.lines[0].utf16.count)
    }

    // MARK: - Inline

    private static func wrap(_ marker: String, in ns: NSString, _ sel: NSRange) -> TextEdit {
        let len = marker.utf16.count
        let selected = ns.substring(with: sel)
        let end = NSMaxRange(sel)
        let before = sel.location >= len ? ns.substring(with: NSRange(location: sel.location - len, length: len)) : ""
        let after = end + len <= ns.length ? ns.substring(with: NSRange(location: end, length: len)) : ""

        if before == marker, after == marker {
            return TextEdit(
                range: NSRange(location: sel.location - len, length: sel.length + 2 * len),
                replacement: selected,
                selection: NSRange(location: sel.location - len, length: sel.length)
            )
        }
        if sel.length >= 2 * len, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: len, length: sel.length - 2 * len))
            return TextEdit(range: sel, replacement: inner, selection: NSRange(location: sel.location, length: inner.utf16.count))
        }
        return TextEdit(range: sel, replacement: marker + selected + marker, selection: NSRange(location: sel.location + len, length: sel.length))
    }

    private static func link(in ns: NSString, _ sel: NSRange) -> TextEdit {
        let selected = ns.substring(with: sel)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            return TextEdit(range: sel, replacement: "[link](\(selected))", selection: NSRange(location: sel.location + 1, length: 4))
        }
        if sel.length > 0 {
            return TextEdit(range: sel, replacement: "[\(selected)](url)", selection: NSRange(location: sel.location + sel.length + 3, length: 3))
        }
        return TextEdit(range: sel, replacement: "[text](url)", selection: NSRange(location: sel.location + 1, length: 4))
    }

    // MARK: - Blocks

    private struct Block {
        var range: NSRange
        var lines: [String]
        var hasTrailingNewline: Bool
    }

    private static func lineBlock(in ns: NSString, _ sel: NSRange) -> Block {
        // A selection that ends right after a newline must not pull in the next line.
        var probe = sel
        if probe.length > 0, ns.substring(with: NSRange(location: NSMaxRange(probe) - 1, length: 1)) == "\n" { probe.length -= 1 }
        let range = ns.lineRange(for: probe)
        let text = ns.substring(with: range)
        let trailing = text.hasSuffix("\n")
        return Block(range: range, lines: (trailing ? String(text.dropLast()) : text).components(separatedBy: "\n"), hasTrailingNewline: trailing)
    }

    private static func blockEdit(_ block: Block, lines: [String], _ sel: NSRange, caretShift: Int) -> TextEdit {
        let body = lines.joined(separator: "\n")
        let replacement = body + (block.hasTrailingNewline ? "\n" : "")
        let selection: NSRange
        if sel.length == 0 {
            selection = NSRange(location: max(block.range.location, sel.location + caretShift), length: 0)
        } else {
            selection = NSRange(location: block.range.location, length: body.utf16.count)
        }
        return TextEdit(range: block.range, replacement: replacement, selection: selection)
    }

    /// Applies or toggles a line prefix (heading, list, task, quote) on every non-empty selected line.
    private static func transform(_ target: Kind, in ns: NSString, _ sel: NSRange) -> TextEdit {
        let block = lineBlock(in: ns, sel)
        let parsed = block.lines.map(parse)
        var active = parsed.indices.filter { !(parsed[$0].rest.isEmpty && parsed[$0].kind == .none) }
        if active.isEmpty { active = Array(parsed.indices) }

        let removing = active.allSatisfy { parsed[$0].kind == target }
        var lines = block.lines
        var number = 1
        for i in active {
            let prefix: String
            switch (removing, target) {
            case (true, _): prefix = ""
            case (_, .heading(let level)): prefix = String(repeating: "#", count: level) + " "
            case (_, .bullet): prefix = "- "
            case (_, .checkbox): prefix = "- [ ] "
            case (_, .numbered): prefix = "\(number). "; number += 1
            case (_, .quote): prefix = "> "
            default: prefix = ""
            }
            lines[i] = parsed[i].indent + prefix + parsed[i].rest
        }

        // Keep the caret on the same text of the first changed line.
        let first = active[0]
        let newPrefix = lines[first].utf16.count - parsed[first].rest.utf16.count
        let shift = newPrefix - parsed[first].prefixLength
        var edit = blockEdit(block, lines: lines, sel, caretShift: shift)
        if sel.length == 0 {
            let offsetInRest = max(0, sel.location - block.range.location - parsed[first].prefixLength)
            edit.selection = NSRange(location: block.range.location + newPrefix + offsetInRest, length: 0)
        }
        return edit
    }

    private static func codeBlock(in ns: NSString, _ sel: NSRange) -> TextEdit {
        let block = lineBlock(in: ns, sel)
        let body = block.lines.joined(separator: "\n")
        let replacement = "```\n" + body + "\n```" + (block.hasTrailingNewline ? "\n" : "")
        return TextEdit(
            range: block.range,
            replacement: replacement,
            selection: NSRange(location: block.range.location + 4, length: sel.length == 0 ? 0 : body.utf16.count)
        )
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    private static func trimmingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
