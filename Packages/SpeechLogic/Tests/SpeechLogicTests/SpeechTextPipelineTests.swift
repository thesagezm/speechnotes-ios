import XCTest
@testable import SpeechLogic

final class SpeechTextPipelineTests: XCTestCase {
    func testPlainTextCleansControlJunk() {
        let md = "# Title\u{00AD}\n\nBody\u{200B} text\u{07} here."
        let spoken = MarkdownText.plainText(md)
        XCTAssertEqual(spoken, "Title\n\nBody text here.")
    }

    func testChunksGlueLoneTrailingFragment() {
        // A fragment too short to synthesize on its own is glued to the piece
        // before it — the engines fail on a one-token tail, not on a short
        // sentence. Here the fast-start sentence is the exempt first piece, so
        // the fragment travels WITH it rather than becoming its own chunk.
        let text = "A complete sentence ends here. x"
        let chunks = SentenceChunker.chunks(for: text, firstMaxChars: 160, batchMaxChars: 160)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[1].text, "x")
        XCTAssertEqual(chunks.map(\.text).joined(), text)
    }

    func testPlainTextNeverLeavesUnspeakableResidue() {
        // The sanitizer removes these at extraction, so plainText's output
        // never carries them into the chunker.
        let md = "# Title\u{00AD}\n\nBody\u{200B} text\u{07} here."
        let spoken = MarkdownText.plainText(md)
        XCTAssertFalse(spoken.unicodeScalars.contains { SpeechSanitizer.isUnspeakable($0) })
    }
}
