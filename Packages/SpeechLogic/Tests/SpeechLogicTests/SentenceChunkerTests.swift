//
//  SentenceChunkerTests.swift
//  SpeechLogic
//
//  Unit tests for the sentence-aware streaming TTS chunker.
//

import XCTest
@testable import SpeechLogic

final class SentenceChunkerTests: XCTestCase {

    // MARK: - Helpers

    /// Substrings `text` at the chunk's UTF-16 offset and length — the same
    /// lookup an NSRange-based progress highlighter would perform.
    private func slice(of text: String, chunk: Chunk) -> String {
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: chunk.offset, limitedBy: utf16.endIndex)!
        let end = utf16.index(start, offsetBy: chunk.length, limitedBy: utf16.endIndex)!
        return String(text[start..<end])
    }

    /// Asserts that chunks are contiguous, never zero-length, that each
    /// chunk's `text` equals its offset/length slice, and that the chunks
    /// together reconstruct the original string exactly.
    private func assertReconstructs(_ text: String, firstMax: Int = 200, batchMax: Int = 400,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let chunks = SentenceChunker.chunks(for: text, firstMaxChars: firstMax, batchMaxChars: batchMax)
        var expectedOffset = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.offset, expectedOffset, "chunk offsets must be contiguous",
                           file: file, line: line)
            XCTAssertEqual(chunk.length, chunk.text.utf16.count, "length must be the UTF-16 length of text",
                           file: file, line: line)
            XCTAssertGreaterThan(chunk.length, 0, "zero-length chunks must never be produced",
                                 file: file, line: line)
            XCTAssertEqual(chunk.text, slice(of: text, chunk: chunk), "chunk text must match its offset/length slice",
                           file: file, line: line)
            expectedOffset = chunk.endOffset
        }
        XCTAssertEqual(expectedOffset, text.utf16.count, "chunks must cover the whole string",
                       file: file, line: line)
        XCTAssertEqual(chunks.map(\.text).joined(), text, "concatenated chunk texts must equal the original",
                       file: file, line: line)
    }

    // MARK: - Basic behavior

    func testSimpleMultiSentenceText() {
        let text = "One two. Three four! Five six? Seven eight."
        let all = SentenceChunker.chunks(for: text)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].text, "One two. ")
        XCTAssertEqual(all[0].offset, 0)
        XCTAssertEqual(all[0].length, 9)
        XCTAssertEqual(all[1].text, "Three four! Five six? Seven eight.")
        XCTAssertEqual(all[1].offset, 9)
        assertReconstructs(text)
    }

    func testFirstChunkIsFirstSentence() {
        let text = "Hello there. General Kenobi!"
        let first = SentenceChunker.firstChunk(in: text)
        XCTAssertEqual(first?.text, "Hello there. ")
        XCTAssertEqual(first?.offset, 0)
        XCTAssertEqual(first?.length, 13)
        XCTAssertEqual(first?.endOffset, 13)
        XCTAssertEqual(SentenceChunker.chunks(for: text).first, first)
        XCTAssertEqual(SentenceChunker.firstChunk(in: "Solo sentence.")?.text, "Solo sentence.")
    }

    func testBatchPackingRespectsBatchMaxChars() {
        let text = "Aaa bbb. Ccc ddd. Eee fff. Ggg hhh. Iii jjj."
        let all = SentenceChunker.chunks(for: text, firstMaxChars: 200, batchMaxChars: 19)
        XCTAssertEqual(all.map(\.text), ["Aaa bbb. ", "Ccc ddd. Eee fff. ", "Ggg hhh. Iii jjj."])
        XCTAssertTrue(all.dropFirst().allSatisfy { $0.length <= 19 })
        assertReconstructs(text, batchMax: 19)

        let tight = SentenceChunker.chunks(for: "Ab. Cd. Ef. Gh.", firstMaxChars: 200, batchMaxChars: 9)
        XCTAssertEqual(tight.map(\.text), ["Ab. ", "Cd. Ef. ", "Gh."])
        XCTAssertEqual(tight.map(\.offset), [0, 4, 12])
        XCTAssertTrue(tight.dropFirst().allSatisfy { $0.length <= 9 })
    }

    func testChunksReconstructOriginalExactly() {
        assertReconstructs("Hello.")
        assertReconstructs("Dr. Smith arrived. He said hi.")
        assertReconstructs("Pi is 3.14 rounded. Build 1.2.3 shipped. Done.")
        assertReconstructs("Wait… what happened? I do not know…")
        assertReconstructs("これはペンです。それもペンです。行こう！戻ろう？")
        assertReconstructs("First line\nSecond line\r\nThird line.\n\nTail without an end")
        assertReconstructs("A.  . B.\n\n?!\n")
        assertReconstructs("Nice 🎉 party. Second 🚀 launch. Tail.", firstMax: 8, batchMax: 12)
        assertReconstructs("🎉🎉🎉🎉", firstMax: 3)
        assertReconstructs("The quick brown fox jumps over the lazy dog again and again", firstMax: 22)
        assertReconstructs(String(repeating: "Sentence number one is here. ", count: 40), batchMax: 60)
    }

    // MARK: - Boundary rules

    func testDecimalsAreNotSplit() {
        XCTAssertEqual(SentenceChunker.firstChunk(in: "Pi is 3.14 rounded.")?.text, "Pi is 3.14 rounded.")
        XCTAssertEqual(SentenceChunker.firstChunk(in: "Version v1.2 shipped today.")?.text, "Version v1.2 shipped today.")
        XCTAssertEqual(SentenceChunker.chunks(for: "Build 1.2.3 passed tests. Great.").map(\.text),
                       ["Build 1.2.3 passed tests. ", "Great."])
        assertReconstructs("Pi is 3.14 rounded. Build 1.2.3 shipped.")
    }

    func testEllipsisHandling() {
        XCTAssertEqual(SentenceChunker.firstChunk(in: "Wait… what happened?")?.text, "Wait… ")
        XCTAssertEqual(SentenceChunker.firstChunk(in: "Hmmm... let me think.")?.text, "Hmmm... ")
        XCTAssertEqual(SentenceChunker.chunks(for: "One… two… three.").map(\.text), ["One… ", "two… three."])
    }

    func testCJKSentenceEnders() {
        let text = "これはペンです。それもペンです。"
        XCTAssertEqual(SentenceChunker.firstChunk(in: text)?.text, "これはペンです。")
        XCTAssertEqual(SentenceChunker.chunks(for: text).map(\.text), ["これはペンです。", "それもペンです。"])
        XCTAssertEqual(SentenceChunker.chunks(for: "行こう！戻ろう？").map(\.text), ["行こう！", "戻ろう？"])
        assertReconstructs(text)
    }

    func testNewlinesAreBoundaries() {
        let text = "First line\nSecond line\nThird line."
        XCTAssertEqual(SentenceChunker.firstChunk(in: text)?.text, "First line\n")
        XCTAssertEqual(SentenceChunker.chunks(for: text).map(\.text), ["First line\n", "Second line\nThird line."])
        XCTAssertEqual(SentenceChunker.firstChunk(in: "Para one.\n\nPara two here.")?.text, "Para one.\n\n")
        XCTAssertEqual(SentenceChunker.firstChunk(in: "One.\r\nTwo.")?.text, "One.\r\n")
        assertReconstructs(text)
    }

    func testUnterminatedParagraphIsSingleChunk() {
        let text = "Just one lone paragraph that never ends with punctuation"
        XCTAssertEqual(SentenceChunker.firstChunk(in: text)?.text, text)
        XCTAssertEqual(SentenceChunker.chunks(for: text).map(\.text), [text])
        XCTAssertEqual(SentenceChunker.chunks(for: text).count, 1)
    }

    // MARK: - Degenerate input

    func testEmptyAndWhitespaceOnlyInput() {
        XCTAssertNil(SentenceChunker.firstChunk(in: ""))
        XCTAssertNil(SentenceChunker.firstChunk(in: "   \t "))
        XCTAssertNil(SentenceChunker.firstChunk(in: "\n \n\r\n"))
        XCTAssertEqual(SentenceChunker.chunks(for: ""), [])
        XCTAssertEqual(SentenceChunker.chunks(for: "  \t "), [])
        XCTAssertEqual(SentenceChunker.chunks(for: "\n\n\n"), [])
    }

    func testLongFirstSentenceSplitsAtWordBoundary() {
        let text = "The quick brown fox jumps over the lazy dog again and again"
        let first = SentenceChunker.firstChunk(in: text, maxChars: 22)
        XCTAssertEqual(first?.text, "The quick brown fox ")
        XCTAssertEqual(first?.length, 20)
        let all = SentenceChunker.chunks(for: text, firstMaxChars: 22, batchMaxChars: 60)
        XCTAssertEqual(all.map(\.text), ["The quick brown fox ", "jumps over the lazy dog again and again"])
        assertReconstructs(text, firstMax: 22, batchMax: 60)

        // No word boundary at all: hard split at maxChars.
        XCTAssertEqual(SentenceChunker.firstChunk(in: "abcdefghijklmnopqrstuvwxyz", maxChars: 10)?.text, "abcdefghij")
    }

    func testNoZeroLengthChunks() {
        let gnarly = "A.  . B.\n\n?!\n. . .\n\n   x"
        let chunks = SentenceChunker.chunks(for: gnarly)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { !$0.text.isEmpty && $0.length > 0 })
        assertReconstructs(gnarly)
    }

    // MARK: - Oversized sentences (TTS per-call token limits)

    func testOversizedSentenceIsSplitAtWordBoundaries() {
        // One 122-char run-on sentence with no terminator, batch cap 20:
        // every chunk must fit the cap and reconstruction must hold.
        let words = (1...20).map { "word\($0)" }
        let runOn = words.joined(separator: " ")
        let all = SentenceChunker.chunks(for: runOn, firstMaxChars: 20, batchMaxChars: 20)
        XCTAssertGreaterThan(all.count, 1)
        XCTAssertTrue(all.allSatisfy { $0.length <= 20 }, "no chunk may exceed batchMaxChars")
        XCTAssertTrue(all.allSatisfy { !$0.text.hasPrefix(" ") })
        assertReconstructs(runOn, firstMax: 20, batchMax: 20)

        // A giant unbroken token hard-cuts rather than exceeding the cap.
        let unbroken = String(repeating: "x", count: 50)
        let hard = SentenceChunker.chunks(for: unbroken, firstMaxChars: 20, batchMaxChars: 20)
        XCTAssertTrue(hard.allSatisfy { $0.length <= 20 })
        assertReconstructs(unbroken, firstMax: 20, batchMax: 20)

        // Mixed: normal sentences around one oversized sentence.
        let mixed = "Short one. " + runOn + " And a short tail."
        let mixedChunks = SentenceChunker.chunks(for: mixed, firstMaxChars: 20, batchMaxChars: 20)
        XCTAssertTrue(mixedChunks.allSatisfy { $0.length <= 20 })
        assertReconstructs(mixed, firstMax: 20, batchMax: 20)
    }

    // MARK: - UTF-16 correctness

    func testUTF16OffsetsWithEmoji() {
        let text = "Nice 🎉 party. Second 🚀 launch. Tail."
        let first = SentenceChunker.firstChunk(in: text, maxChars: 8)
        XCTAssertEqual(first?.text, "Nice 🎉 ")
        XCTAssertEqual(first?.length, 8)
        XCTAssertEqual(first?.offset, 0)
        assertReconstructs(text, firstMax: 8, batchMax: 12)

        // A cut budget that would land inside a surrogate pair snaps to the
        // last whole Character instead.
        XCTAssertEqual(SentenceChunker.firstChunk(in: "🎉🎉🎉🎉", maxChars: 3)?.text, "🎉")
    }
}
