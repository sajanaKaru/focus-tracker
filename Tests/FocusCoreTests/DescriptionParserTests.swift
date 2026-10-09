import XCTest
@testable import FocusCore

final class DescriptionParserTests: XCTestCase {
    func testSplitsMarkdownAndHTMLImages() {
        let body = "Intro\n![shot](https://example.com/a.png)\nMiddle <img width=\"10\" alt=\"b\" src=\"https://example.com/b.png?x=1&amp;y=2\"> end"
        let blocks = DescriptionParser.blocks(from: body)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[1], .image(url: "https://example.com/a.png", alt: "shot"))
        XCTAssertEqual(blocks[3], .image(url: "https://example.com/b.png?x=1&y=2", alt: "b"))
    }

    func testPlainTextHasNoImages() {
        XCTAssertEqual(DescriptionParser.blocks(from: "just text"), [.text("just text")])
    }

    func testImageURLsFromHTML() {
        let html = "<p><a href=\"x\"><img src=\"https://p.example/1.png?jwt=a&amp;b\" alt=\"\"></a></p>"
        XCTAssertEqual(DescriptionParser.imageURLs(fromHTML: html), ["https://p.example/1.png?jwt=a&b"])
    }
}
