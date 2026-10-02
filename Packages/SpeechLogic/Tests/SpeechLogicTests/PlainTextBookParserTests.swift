import XCTest
@testable import SpeechLogic

/// Plain-text and Markdown book parsing: heading detection, chapter splitting
/// and the encoding battery, against the shapes Project Gutenberg actually
/// ships.
final class PlainTextBookParserTests: XCTestCase {

    func testMarkdownHeadingsBecomeChapters() throws {
        let text = """
        # Part One
        Alpha prose.
        Beta prose.
        ## Chapter Inside
        Gamma prose.
        # Part Two
        Delta prose.
        """
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        XCTAssertEqual(chapters.map(\.title), ["Part One", "Chapter Inside", "Part Two"])
        XCTAssertEqual(chapters[0].paragraphs, ["Alpha prose.", "Beta prose."])
        XCTAssertEqual(chapters[1].paragraphs, ["Gamma prose."])
        XCTAssertEqual(chapters[2].paragraphs, ["Delta prose."])
    }

    func testGutenbergRunningHeadingsBecomeChapters() throws {
        let text = """
        Chapter 1

        It was a bright morning and the lamp post stood quiet.

        CHAPTER II

        The second chapter opened with a letter.

        Part Two

        Nothing happened for eleven days.
        """
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        XCTAssertEqual(chapters.map(\.title), ["Chapter 1", "CHAPTER II", "Part Two"])
        XCTAssertEqual(chapters[0].paragraphs, ["It was a bright morning and the lamp post stood quiet."])
    }

    func testProseLinesReflowIntoParagraphs() throws {
        // Gutenberg hard-wraps at ~70 columns; the split would otherwise make
        // one sentence three paragraphs and the chunker would cut mid-sentence.
        let text = """
        Chapter One

        It was a bright morning and the lamp post stood
        quiet. The boy walked home through the fog,
        counting the steps he had taken since Tuesday.
        """
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(
            chapters[0].paragraphs,
            ["It was a bright morning and the lamp post stood quiet. The boy walked home through the fog, counting the steps he had taken since Tuesday."]
        )
    }

    func testHeadlessTextChunks() throws {
        let paragraphs = (0..<400).map { "Paragraph \($0)." }
        let text = paragraphs.joined(separator: "\n\n")
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        // 400 paragraphs / 150 → 3 chapters, all untitled.
        XCTAssertEqual(chapters.count, 3)
        XCTAssertTrue(chapters.allSatisfy { $0.title == nil })
        XCTAssertEqual(chapters[0].paragraphs.count, 150)
        XCTAssertEqual(chapters[2].paragraphs.count, 100)
    }

    func testHeadingCarriesOntoItsContinuation() throws {
        let body = (0..<320).map { "Paragraph \($0)." }
        let text = "# One Long Chapter\n\n" + body.joined(separator: "\n\n")
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        XCTAssertEqual(chapters.count, 3)
        XCTAssertTrue(chapters.allSatisfy { $0.title == "One Long Chapter" })
    }

    func testNumberedHeadingDetected() throws {
        let text = """
        I. The Garden

        Prose under the numbered head.

        12. The Return

        More prose.
        """
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        XCTAssertEqual(chapters.map(\.title), ["I. The Garden", "12. The Return"])
    }

    func testShortSentenceIsNotMistakenForAHeading() throws {
        // "Yes." ends with punctuation and is prose, whatever its length.
        let text = """
        Chapter One

        Yes.

        More prose follows here.
        """
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].paragraphs, ["Yes.", "More prose follows here."])
    }

    func testMarkdownInlineMarkupIsStripped() throws {
        let text = """
        # A **Bold** Title
        This is *emphasised*, this is `code`, and [a link](https://example.com/x).
        """
        let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
        XCTAssertEqual(chapters[0].title, "A Bold Title")
        XCTAssertEqual(chapters[0].paragraphs, ["This is emphasised, this is code, and a link."])
    }

    func testEncodingBatteryDecodesBOMmedUTF16() throws {
        let utf16 = """
        Chapter One

        Was ist das? Café-crème — naïve.
        """
        let data = utf16.data(using: .utf16BigEndian)!   // includes the BOM
        let chapters = try PlainTextBookParser.parse(archive: data)
        XCTAssertEqual(chapters[0].title, "Chapter One")
        XCTAssertEqual(chapters[0].paragraphs[0], "Was ist das? Café-crème — naïve.")
    }

    func testLatin1FallbackForBOMlessHighBytes() throws {
        // "Café" as latin-1: no BOM, and 0xE9 is not valid UTF-8, so the
        // battery must land on latin-1 — NOT on a UTF-16 decode of the byte
        // pairs, which "succeeds" into CJK garbage (the first draft's bug).
        let bytes: [UInt8] = Array("Caf".utf8) + [0xE9]
        let chapters = try PlainTextBookParser.parse(archive: Data(bytes))
        XCTAssertEqual(chapters[0].paragraphs[0], "Café")
    }

    func testEmptyFileThrows() {
        XCTAssertThrowsError(try PlainTextBookParser.parse(archive: Data()))
        XCTAssertThrowsError(try PlainTextBookParser.parse(archive: Data("   \n\n  ".utf8)))
    }

    func testLineBreakVariantsAllSplit() throws {
        for (label, separator) in [("crlf", "\r\n"), ("cr", "\r"), ("lf", "\n")] {
            let text = "Chapter One\(separator)Prose one.\(separator)\(separator)Prose two."
            let chapters = try PlainTextBookParser.parse(archive: Data(text.utf8))
            XCTAssertEqual(chapters.count, 1, label)
            XCTAssertEqual(chapters[0].paragraphs, ["Prose one.", "Prose two."], label)
        }
    }
}
