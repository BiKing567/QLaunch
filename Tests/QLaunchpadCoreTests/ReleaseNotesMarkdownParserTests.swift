import XCTest
@testable import QLaunchpadCore

final class ReleaseNotesMarkdownParserTests: XCTestCase {
    func testHeaderParsing() {
        let md = """
        # Title 1
        ## Title 2
        ### Title 3
        #### Title 4
        """
        let blocks = ReleaseNotesMarkdownParser.parse(md)
        XCTAssertEqual(blocks, [
            .header(level: 1, text: "Title 1"),
            .header(level: 2, text: "Title 2"),
            .header(level: 3, text: "Title 3"),
            .header(level: 4, text: "Title 4")
        ])
    }

    func testListAndDividers() {
        let md = """
        - Item 1
        * Item 2
        + Item 3
        ---
        1. Step 1
        2. Step 2
        """
        let blocks = ReleaseNotesMarkdownParser.parse(md)
        XCTAssertEqual(blocks, [
            .listItem(ordered: false, index: 0, text: "Item 1"),
            .listItem(ordered: false, index: 0, text: "Item 2"),
            .listItem(ordered: false, index: 0, text: "Item 3"),
            .divider,
            .listItem(ordered: true, index: 1, text: "Step 1"),
            .listItem(ordered: true, index: 2, text: "Step 2")
        ])
    }

    func testCodeBlocksAndQuotes() {
        let md = """
        > Important note

        ```swift
        let a = 1
        let b = 2
        ```
        """
        let blocks = ReleaseNotesMarkdownParser.parse(md)
        XCTAssertEqual(blocks, [
            .blockQuote(text: "Important note"),
            .codeBlock(code: "let a = 1\nlet b = 2")
        ])
    }

    func testIndentedListContinuation() {
        let md = """
        - First bullet line
          second bullet line
        """
        let blocks = ReleaseNotesMarkdownParser.parse(md)
        XCTAssertEqual(blocks, [
            .listItem(ordered: false, index: 0, text: "First bullet line second bullet line")
        ])
    }

    func testParagraphJoining() {
        let md = """
        This is a paragraph
        that spans across
        three lines.

        And a second paragraph.
        """
        let blocks = ReleaseNotesMarkdownParser.parse(md)
        XCTAssertEqual(blocks, [
            .paragraph(text: "This is a paragraph that spans across three lines."),
            .paragraph(text: "And a second paragraph.")
        ])
    }
}
