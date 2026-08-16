//
//  SentenceChunker.swift
//  SpeechLogic
//
//  Sentence-aware text chunking for streaming TTS playback in Speechnotes.
//
//  The strategy — emit the first sentence immediately for a fast playback
//  start, then greedily pack consecutive sentences into bounded batches for
//  throughput — is an independent Swift implementation written for Speechnotes
//  after observing the behavior of the MIT-licensed PocketPal AI project's
//  `StreamingChunker`.
//

import Foundation

/// A contiguous slice of the original text, destined for a single TTS
/// synthesis request.
///
/// `offset` and `length` are UTF-16 based so a chunk can be mapped directly
/// onto an `NSRange` of the original string for playback-progress highlighting
/// in SwiftUI.
public struct Chunk: Equatable {

    /// The literal chunk text, exactly as it appears in the original string.
    public let text: String

    /// Absolute UTF-16 index of the chunk's first character within the
    /// original text.
    public let offset: Int

    /// UTF-16 length of `text`; always equal to `text.utf16.count`.
    public let length: Int

    /// Creates a chunk value.
    public init(text: String, offset: Int, length: Int) {
        self.text = text
        self.offset = offset
        self.length = length
    }

    /// Absolute UTF-16 index one past the chunk's last character.
    public var endOffset: Int { offset + length }
}

/// Splits text into sentence-aware chunks for streaming text-to-speech.
///
/// Boundary rules, in order of precedence:
/// * A run of `.`, `!`, `?`, `…` ends a sentence when followed by whitespace
///   or the end of the text.
/// * `。`, `！`, `？` (CJK terminators) always end a sentence.
/// * Newlines (`\n`, `\r`, `\r\n`, U+2028, U+2029) always end a sentence —
///   in a notes app, line breaks are natural boundaries.
/// * A `.` between two digits is not a boundary (`3.14`, `v1.2`).
/// * Terminating punctuation and the whitespace that follows it (including
///   newlines and blank lines) belong to the chunk they terminate, so
///   concatenating all chunk texts reproduces the original string exactly.
///
/// Abbreviations such as "Dr." are split on a best-effort basis. All
/// operations are pure functions with no shared mutable state.
public enum SentenceChunker {

    // MARK: - Character classes

    /// Terminators that require trailing whitespace (or end of text) to end
    /// a sentence.
    private static let asciiTerminators: Set<Character> = [".", "!", "?", "…"]

    /// CJK terminators that unconditionally end a sentence.
    private static let cjkTerminators: Set<Character> = ["。", "！", "？"]

    /// Line-break characters that unconditionally end a sentence.
    private static let lineBreaks: Set<Character> = ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"]

    // MARK: - Public API

    /// Returns the first sentence of `text` so speech playback can start fast.
    ///
    /// - Parameters:
    ///   - text: The full text to be spoken.
    ///   - maxChars: Maximum UTF-16 length of the returned chunk. Values below
    ///     1 are treated as 1.
    /// - Returns: The first sentence, or `nil` when `text` is empty or
    ///   whitespace-only. When the first sentence exceeds `maxChars`, the chunk
    ///   is cut at the last word boundary within the limit; if the text has no
    ///   whitespace at all, it is hard-cut at `maxChars`.
    public static func firstChunk(in text: String, maxChars: Int = 200) -> Chunk? {
        guard !text.isEmpty, text.contains(where: { !$0.isWhitespace }) else { return nil }

        let window = max(1, maxChars)
        let limit = utf16CappedIndex(text, from: text.startIndex, maxUtf16Length: window)

        // Leading whitespace belongs to the first chunk; boundary scanning
        // starts at the first non-whitespace character.
        var body = text.startIndex
        while body < limit, text[body].isWhitespace {
            body = text.index(after: body)
        }

        if let end = sentenceEnd(in: text, from: body, limit: limit) {
            return chunk(in: text, from: text.startIndex, to: end)
        }
        if limit == text.endIndex {
            // The whole text fits and has no boundary: one unterminated sentence.
            return chunk(in: text, from: text.startIndex, to: text.endIndex)
        }
        if let cut = lastWordBoundary(in: text, from: body, limit: limit) {
            return chunk(in: text, from: text.startIndex, to: cut)
        }
        return chunk(in: text, from: text.startIndex, to: limit)
    }

    /// Splits `text` into ordered chunks for streaming playback.
    ///
    /// - Parameters:
    ///   - text: The full text to be spoken.
    ///   - firstMaxChars: Maximum UTF-16 length of the fast-start first chunk.
    ///   - batchMaxChars: Maximum total UTF-16 length of every later chunk.
    ///     Consecutive whole sentences are packed greedily up to this limit,
    ///     and a single sentence longer than the limit is split at word
    ///     boundaries into pieces that each fit — downstream TTS engines
    ///     enforce per-call token limits, so no chunk may be oversized.
    /// - Returns: All chunks in order. The first element is `firstChunk(in:)`;
    ///   substrings taken at each chunk's offset/length reproduce `text`
    ///   exactly. Empty for empty or whitespace-only input.
    public static func chunks(for text: String, firstMaxChars: Int = 200, batchMaxChars: Int = 400) -> [Chunk] {
        guard let first = firstChunk(in: text, maxChars: firstMaxChars) else { return [] }

        var result = [first]
        let maxBatchLength = max(1, batchMaxChars)
        let utf16 = text.utf16

        var cursor = utf16.index(utf16.startIndex, offsetBy: first.length, limitedBy: utf16.endIndex) ?? utf16.endIndex

        // Pass 1 — scan sentence ranges; pass 2 — split any oversized
        // sentence at word boundaries so every piece fits the batch limit.
        var pieces: [(start: String.Index, end: String.Index)] = []
        while cursor < text.endIndex {
            let end = sentenceEnd(in: text, from: cursor, limit: text.endIndex) ?? text.endIndex
            pieces.append(contentsOf: splitOversized(text, start: cursor, end: end, maxUtf16: maxBatchLength))
            cursor = end
        }

        // Pass 3 — pack pieces greedily into batches up to the limit.
        var batchStart: String.Index?
        var batchEnd: String.Index?
        var batchLength = 0
        for piece in pieces {
            let pieceLength = text[piece.start..<piece.end].utf16.count
            if batchLength == 0 {
                batchStart = piece.start
                batchEnd = piece.end
                batchLength = pieceLength
            } else if batchLength + pieceLength <= maxBatchLength {
                batchEnd = piece.end
                batchLength += pieceLength
            } else {
                result.append(chunk(in: text, from: batchStart!, to: batchEnd!))
                batchStart = piece.start
                batchEnd = piece.end
                batchLength = pieceLength
            }
        }
        if batchLength > 0 {
            result.append(chunk(in: text, from: batchStart!, to: batchEnd!))
        }
        return result
    }

    /// Splits the sentence span `start..<end` into pieces whose UTF-16 length
    /// never exceeds `maxUtf16`. Cuts land on word boundaries (after the
    /// whitespace run) whenever one exists in the window; text with no
    /// whitespace at all is hard-cut at the cap. Pieces partition the span
    /// exactly — contiguity with the surrounding chunks is preserved.
    private static func splitOversized(
        _ text: String,
        start: String.Index,
        end: String.Index,
        maxUtf16: Int
    ) -> [(start: String.Index, end: String.Index)] {
        guard text[start..<end].utf16.count > maxUtf16 else {
            return [(start, end)]
        }
        var pieces: [(start: String.Index, end: String.Index)] = []
        var pieceStart = start
        while pieceStart < end {
            let limit = utf16CappedIndex(text, from: pieceStart, maxUtf16Length: maxUtf16)
            if limit >= end {
                pieces.append((pieceStart, end))
                break
            }
            let cut: String.Index
            if let wordCut = lastWordBoundary(in: text, from: pieceStart, limit: limit),
               wordCut > pieceStart {
                cut = wordCut
            } else {
                cut = limit
            }
            pieces.append((pieceStart, cut))
            pieceStart = cut
        }
        return pieces
    }

    // MARK: - Sentence scanning

    /// Finds the exclusive end index of the sentence starting at `start`.
    ///
    /// The returned index includes the terminating punctuation run and any
    /// whitespace following it (spaces, tabs, newlines). Scanning never looks
    /// past `limit`; reaching `limit` right after a terminator run counts as
    /// the end of a sentence. Returns `nil` when no boundary exists at or
    /// before `limit`.
    private static func sentenceEnd(in text: String, from start: String.Index, limit: String.Index) -> String.Index? {
        var i = start
        while i < limit {
            let c = text[i]

            if asciiTerminators.contains(c) || cjkTerminators.contains(c) {
                // Consume the whole run of terminator punctuation.
                var j = i
                var sawCJKTerminator = false
                while j < limit {
                    let t = text[j]
                    if asciiTerminators.contains(t) {
                        j = text.index(after: j)
                    } else if cjkTerminators.contains(t) {
                        sawCJKTerminator = true
                        j = text.index(after: j)
                    } else {
                        break
                    }
                }

                // CJK terminators and end-of-window/end-of-text are automatic;
                // ASCII terminators need whitespace (or end) after the run.
                var isBoundary = sawCJKTerminator || j == limit || text[j].isWhitespace

                // A period between two digits ("3.14", "v1.2") is not a boundary.
                if isBoundary, c == ".", text.index(after: i) == j, i > text.startIndex,
                   text[text.index(before: i)].isNumber, j < text.endIndex, text[j].isNumber {
                    isBoundary = false
                }

                if isBoundary {
                    var k = j
                    while k < limit, text[k].isWhitespace {
                        k = text.index(after: k)
                    }
                    return k
                }

                i = j
                continue
            }

            if lineBreaks.contains(c) {
                // Newlines are hard boundaries; the whitespace after them
                // (including blank lines) belongs to the chunk being terminated.
                var k = i
                while k < limit, text[k].isWhitespace {
                    k = text.index(after: k)
                }
                return k
            }

            i = text.index(after: i)
        }
        return nil
    }

    /// Returns the end of the last whitespace run at or before `limit`
    /// (a word-boundary split point), or `nil` if there is no whitespace.
    private static func lastWordBoundary(in text: String, from start: String.Index, limit: String.Index) -> String.Index? {
        var cut: String.Index?
        var i = start
        while i < limit {
            if text[i].isWhitespace {
                var j = i
                while j < limit, text[j].isWhitespace {
                    j = text.index(after: j)
                }
                cut = j
                i = j
            } else {
                i = text.index(after: i)
            }
        }
        return cut
    }

    // MARK: - Index helpers

    /// Returns an index at most `maxUtf16Length` UTF-16 units after `start`,
    /// always aligned to a Character boundary (never mid-grapheme).
    private static func utf16CappedIndex(_ text: String, from start: String.Index, maxUtf16Length: Int) -> String.Index {
        var index = start
        var used = 0
        while index < text.endIndex {
            let cost = text[index].utf16.count
            if used + cost > maxUtf16Length {
                break
            }
            used += cost
            index = text.index(after: index)
        }
        return index
    }

    /// The UTF-16 offset of `index` within `text`, suitable for `NSRange`.
    private static func utf16Offset(of index: String.Index, in text: String) -> Int {
        text.utf16.distance(from: text.startIndex, to: index)
    }

    /// Builds a `Chunk` spanning `from`..<`to` in `text`.
    private static func chunk(in text: String, from: String.Index, to: String.Index) -> Chunk {
        let slice = text[from..<to]
        return Chunk(
            text: String(slice),
            offset: utf16Offset(of: from, in: text),
            length: slice.utf16.count
        )
    }
}
