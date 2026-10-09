import XCTest
@testable import FocusCore

final class MarkdownFormatterTests: XCTestCase {
    /// Applies an edit and returns the resulting text with `|` marking the caret or `[ ]` the selection.
    private func apply(_ edit: TextEdit?, to text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let edit else { XCTFail("no edit", file: file, line: line); return "" }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        if edit.selection.length == 0 {
            return result.replacingCharacters(in: edit.selection, with: "|")
        }
        let closed = result.replacingCharacters(in: NSRange(location: NSMaxRange(edit.selection), length: 0), with: "]") as NSString
        return closed.replacingCharacters(in: NSRange(location: edit.selection.location, length: 0), with: "[")
    }

    private func run(_ action: MarkdownAction, _ text: String, _ selection: NSRange) -> String {
        apply(MarkdownFormatter.edit(action, in: text, selection: selection), to: text)
    }

    func testBoldWrapsAndUnwrapsSelection() {
        XCTAssertEqual(run(.bold, "make it so", NSRange(location: 5, length: 2)), "make **[it]** so")
        XCTAssertEqual(run(.bold, "make **it** so", NSRange(location: 7, length: 2)), "make [it] so")
        XCTAssertEqual(run(.bold, "", NSRange(location: 0, length: 0)), "**|**")
        XCTAssertEqual(run(.bold, "****", NSRange(location: 2, length: 0)), "|")
    }

    func testLinkUsesSelectionAsTextOrUrl() {
        XCTAssertEqual(run(.link, "see docs", NSRange(location: 4, length: 4)), "see [docs]([url])")
        XCTAssertEqual(run(.link, "https://a.dev", NSRange(location: 0, length: 13)), "[[link]](https://a.dev)")
        XCTAssertEqual(run(.link, "", NSRange(location: 0, length: 0)), "[[text]](url)")
    }

    func testHeadingTogglesAndReplacesLevel() {
        XCTAssertEqual(run(.heading(1), "Title", NSRange(location: 5, length: 0)), "# Title|")
        XCTAssertEqual(run(.heading(2), "# Title", NSRange(location: 7, length: 0)), "## Title|")
        XCTAssertEqual(run(.heading(2), "## Title", NSRange(location: 8, length: 0)), "Title|")
    }

    func testListActionsApplyToEveryNonEmptyLineAndToggleOff() {
        let text = "one\n\ntwo\nthree"
        let all = NSRange(location: 0, length: text.utf16.count)

        XCTAssertEqual(run(.numbered, text, all), "[1. one\n\n2. two\n3. three]")
        XCTAssertEqual(run(.checkbox, "- a\n- b", NSRange(location: 0, length: 7)), "[- [ ] a\n- [ ] b]")
        XCTAssertEqual(run(.bullet, "- a\n- b", NSRange(location: 0, length: 7)), "[a\nb]")
        XCTAssertEqual(run(.bullet, "", NSRange(location: 0, length: 0)), "- |")
    }

    func testSelectionEndingAtNewlineDoesNotTouchNextLine() {
        XCTAssertEqual(run(.bullet, "a\nb", NSRange(location: 0, length: 2)), "[- a]\nb")
    }

    func testCaretStaysOnSameTextWhenPrefixChanges() {
        XCTAssertEqual(run(.bullet, "hello", NSRange(location: 2, length: 0)), "- he|llo")
    }

    func testCodeBlockAndQuote() {
        XCTAssertEqual(run(.codeBlock, "", NSRange(location: 0, length: 0)), "```\n|\n```")
        XCTAssertEqual(run(.codeBlock, "let a = 1", NSRange(location: 0, length: 9)), "```\n[let a = 1]\n```")
        XCTAssertEqual(run(.quote, "hi", NSRange(location: 0, length: 2)), "[> hi]")
    }

    func testReturnContinuesListsAndEndsOnEmptyItem() {
        func ret(_ text: String) -> String { apply(MarkdownFormatter.newline(in: text, selection: NSRange(location: text.utf16.count, length: 0)), to: text) }

        XCTAssertEqual(ret("- one"), "- one\n- |")
        XCTAssertEqual(ret("  * one"), "  * one\n  * |")
        XCTAssertEqual(ret("3. three"), "3. three\n4. |")
        XCTAssertEqual(ret("- [x] done"), "- [x] done\n- [ ] |")
        XCTAssertEqual(ret("> quoted"), "> quoted\n> |")
        XCTAssertEqual(ret("- one\n- "), "- one\n|")
        XCTAssertNil(MarkdownFormatter.newline(in: "plain", selection: NSRange(location: 5, length: 0)))
        XCTAssertNil(MarkdownFormatter.newline(in: "# Title", selection: NSRange(location: 7, length: 0)))
    }

    func testTabIndentsOnlyListLinesAndShiftTabOutdents() {
        XCTAssertEqual(apply(MarkdownFormatter.indent(in: "- a", selection: NSRange(location: 3, length: 0), outdent: false, onlyLists: true), to: "- a"), "  - a|")
        XCTAssertEqual(apply(MarkdownFormatter.indent(in: "1. a", selection: NSRange(location: 4, length: 0), outdent: false, onlyLists: true), to: "1. a"), "   1. a|")
        XCTAssertNil(MarkdownFormatter.indent(in: "plain", selection: NSRange(location: 0, length: 0), outdent: false, onlyLists: true))
        XCTAssertEqual(apply(MarkdownFormatter.indent(in: "  - a", selection: NSRange(location: 5, length: 0), outdent: true, onlyLists: true), to: "  - a"), "- a|")
        XCTAssertNil(MarkdownFormatter.indent(in: "- a", selection: NSRange(location: 3, length: 0), outdent: true, onlyLists: true))
    }
}
