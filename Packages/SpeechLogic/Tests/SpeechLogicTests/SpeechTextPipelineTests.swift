import XCTest
@testable import SpeechLogic

final class SpeechTextPipelineTests: XCTestCase {
    func testPlainTextCleansControlJunk() {
        let md = "# Title\u{00AD}\n\nBody\u{200B} text\u{07} here."
        let spoken = MarkdownText.plainText(md)
        XCTAssertEqual(spoken, "Title\n\nBodytext here.")
    }

    func testChunksDropPunctuationOnlyPiece() {
        let text = "Real sentence here.\n***\nAnother real sentence."
        let chunks = SentenceChunker.chunks(for: text, firstMaxChars: 160, batchMaxChars: 160)
        XCTAssertFalse(chunks.contains { $0.text.contains("***") })
        XCTAssertEqual(chunks.map(\.text).joined(), "Real sentence here.Another real sentence.")
    }

    func testChunksGlueLoneTrailingFragment() {
        let text = "A complete sentence ends here. x"
        let chunks = SentenceChunker.chunks(for: text, firstMaxChars: 160, batchMaxChars: 160)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.hasSuffix("x"))
    }
}
