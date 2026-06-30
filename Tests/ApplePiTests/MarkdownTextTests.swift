import Testing
@testable import ApplePi
@testable import ApplePiCore
@testable import ApplePiRemote

@Suite("MarkdownText parser")
struct MarkdownTextTests {
    @Test
    func emptyInputProducesNoBlocks() {
        #expect(MarkdownText.parseBlocks("").isEmpty)
    }

    @Test
    func parsesParagraphsAndHeadings() {
        let blocks = MarkdownText.parseBlocks("# Title\n\nHello **world**")

        #expect(blocks.map(\.kind) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Hello **world**")
        ])
    }

    @Test
    func parsesUnorderedAndOrderedLists() {
        let blocks = MarkdownText.parseBlocks("- first\n- second\n\n1. one\n2. two")

        #expect(blocks.map(\.kind) == [
            .unorderedItem("first"),
            .unorderedItem("second"),
            .orderedItem(marker: "1.", text: "one"),
            .orderedItem(marker: "2.", text: "two")
        ])
    }

    @Test
    func parsesFencedCodeBlocks() {
        let markdown = """
        Before

        ```swift
        let value = 42
        print(value)
        ```

        After
        """

        let blocks = MarkdownText.parseBlocks(markdown)

        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .paragraph("Before"))
        #expect(blocks[1].kind == .code(language: "swift", code: "let value = 42\nprint(value)"))
        #expect(blocks[2].kind == .paragraph("After"))
    }

    @Test
    func parsesBlockQuotesAndHorizontalRules() {
        let blocks = MarkdownText.parseBlocks("> first\n> second\n\n---\n\nDone")

        #expect(blocks.map(\.kind) == [
            .quote("first\nsecond"),
            .rule,
            .paragraph("Done")
        ])
    }
}
