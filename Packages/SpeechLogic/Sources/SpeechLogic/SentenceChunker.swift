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
    ///     Deliberately SMALLER than `batchMaxChars` so chunk 0 is one short
    ///     sentence (fast TTFA) while chunk 1 packs to the batch limit to
    ///     cover the following-sentence wait (v0.4's `firstMaxChars: 200,
    ///     batchMaxChars: 400` asymmetry; v0.5.2 collapsed it, re-creating a
    ///     ~4.3 s dead-air stall between sentence 1 and sentence 2 — see
    ///     TTS_BASELINE §2 and TTS_REGRESSION_AUDIT R16).
    ///   - batchMaxChars: Maximum total UTF-16 length of every later chunk.
    ///     Consecutive whole sentences are packed greedily up to this limit,
    ///     and a single sentence longer than the limit is split at word
    ///     boundaries into pieces that each fit — downstream TTS engines
    ///     enforce per-call token limits, so no chunk may be oversized.
    ///   - minOpenerChars: The opener's MINIMUM size, in UTF-16 units.
    ///     `firstChunk` stops at the FIRST sentence that fits the cap, so a
    ///     text whose first sentence is short produces a short opener no
    ///     matter how large the cap is — and a short opener is exactly what
    ///     runs out of audio before the second buffer arrives (the audible
    ///     gap the chunk schedule exists to close). When this is > 0, whole
    ///     following sentences are appended to the opener until it reaches
    ///     `minOpenerChars` UTF-16 units, never past `batchMaxChars`.
    ///
    ///     The cap is `minOpenerChars` ITSELF, not `max(firstMaxChars,
    ///     minOpenerChars)`: `firstMaxChars` bounds the FIRST SENTENCE, and
    ///     folding it into the opener cap would let a large `firstMaxChars`
    ///     (the default 200) grow the opener far past what was asked for.
    ///
    ///     DEFAULT OFF (0): the opener is exactly `firstChunk(in:maxChars:)`,
    ///     so every existing behaviour — and the doc contract above — is
    ///     unchanged. Production callers opt in, and pass the same value
    ///     for `firstMaxChars` and `minOpenerChars` — the opener's total
    ///     size is the budget, and the first sentence is merely where it
    ///     starts.
    /// - Returns: All chunks in order. The first element is `firstChunk(in:)`
    ///   (extended to `minOpenerChars` when that is asked for); substrings
    ///   taken at each chunk's offset/length reproduce `text` exactly. Empty
    ///   for empty or whitespace-only input.
    public static func chunks(
        for text: String,
        firstMaxChars: Int = 80,
        batchMaxChars: Int = 400,
        minOpenerChars: Int = 0
    ) -> [Chunk] {
        let maxBatchLength = max(1, batchMaxChars)
        let wantsCompletion = minOpenerChars > 0
        // The opener's cap. `minOpenerChars` IS the opener's TOTAL size —
        // the first sentence is merely where it starts. The batch ceiling
        // is the hard cap on any chunk, so the opener never exceeds it.
        let openerCap = wantsCompletion ? min(max(1, minOpenerChars), maxBatchLength) : 0
        // The first sentence's own cap: the opener's cap when completion is
        // on, so an inconsistent caller (a `firstMaxChars` above the
        // engine's ceiling) cannot produce an oversized opener. Otherwise
        // the caller's `firstMaxChars`, unchanged.
        let firstCap = wantsCompletion ? min(max(1, firstMaxChars), openerCap) : firstMaxChars
        guard let first = firstChunk(in: text, maxChars: firstCap) else { return [] }

        var result = [first]
        // A piece with NOTHING to say — no character at all, or only the
        // punctuation/whitespace residue a document leaves behind — is glued
        // onto the piece before it instead of being handed to the engine. That
        // is the case the engines actually fail on: an empty phoneme tail makes
        // Kokoro's style lookup non-finite and Supertonic's duration predictor
        // return nothing. A short but real sentence ("Ok.") is left alone — it
        // speaks fine, and gluing it would break the packing contract the
        // tests pin.
        let minPieceLength = min(maxBatchLength, 4)
        let utf16 = text.utf16

        var cursor = utf16.index(utf16.startIndex, offsetBy: first.length, limitedBy: utf16.endIndex) ?? utf16.endIndex

        // Opener completion — opt-in (see the parameter docs). The opener
        // grows by WHOLE following sentences, never by a cut, so it still
        // ends at a sentence boundary the engine can speak cleanly.
        if wantsCompletion {
            if let completed = completedOpenerEnd(
                in: text,
                after: first,
                cap: openerCap,
                maxBatchLength: maxBatchLength
            ) {
                result[0] = chunk(in: text, from: text.startIndex, to: completed)
                cursor = completed
            }
        }

        // Pass 1 + 2 — scan sentence ranges and split any oversized sentence
        // at word boundaries so every piece fits the batch limit.
        let batchPieces = pieces(in: text, from: cursor, maxBatchLength: maxBatchLength, minPieceLength: minPieceLength)

        // Pass 3 — pack pieces greedily into batches up to the limit.
        var batchStart: String.Index?
        var batchEnd: String.Index?
        var batchLength = 0
        for piece in batchPieces {
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

    /// The sentence pieces of `text` from `start` onward, each no longer
    /// than `maxBatchLength`, with the short-fragment glue applied.
    ///
    /// A trailing fragment too short to synthesize on its own is glued onto
    /// the previous piece so the engines never see a stub (an empty or
    /// one-token tail is what makes Kokoro's style lookup non-finite).
    /// Nothing is ever dropped: the pieces must still concatenate to the
    /// original text, which is what the read-along and the resume offset
    /// both rely on.
    private static func pieces(
        in text: String,
        from start: String.Index,
        maxBatchLength: Int,
        minPieceLength: Int
    ) -> [(start: String.Index, end: String.Index)] {
        var pieces: [(start: String.Index, end: String.Index)] = []
        var cursor = start
        while cursor < text.endIndex {
            let end = sentenceEnd(in: text, from: cursor, limit: text.endIndex) ?? text.endIndex
            for piece in splitOversized(text, start: cursor, end: end, maxUtf16: maxBatchLength) {
                if let last = pieces.last {
                    let lastLength = text[last.start..<last.end].utf16.count
                    let pieceLength = text[piece.start..<piece.end].utf16.count
                    if pieceLength < minPieceLength, lastLength + pieceLength <= maxBatchLength + minPieceLength {
                        pieces[pieces.count - 1] = (last.start, piece.end)
                        continue
                    }
                }
                pieces.append(piece)
            }
            cursor = end
        }
        return pieces
    }

    /// Extends an opener with WHOLE following sentences, up to `cap`
    /// UTF-16 units in total, and returns where the next chunk must start.
    ///
    /// Only complete pieces are appended: a sentence that does not fit in
    /// the remaining budget is left whole for the next chunk, because a cut
    /// opener would end on a clipped word.
    ///
    /// Returns nil when nothing could be appended — the opener stays as it
    /// was.
    private static func completedOpenerEnd(
        in text: String,
        after first: Chunk,
        cap: Int,
        maxBatchLength: Int
    ) -> String.Index? {
        guard cap > first.length else { return nil }
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: first.length, limitedBy: utf16.endIndex) ?? utf16.endIndex
        guard start < text.endIndex else { return nil }
        var cursor = start
        var used = first.length
        while cursor < text.endIndex {
            let end = sentenceEnd(in: text, from: cursor, limit: text.endIndex) ?? text.endIndex
            for piece in splitOversized(text, start: cursor, end: end, maxUtf16: maxBatchLength) {
                let pieceLength = text[piece.start..<piece.end].utf16.count
                guard used + pieceLength <= cap else { return cursor }
                used += pieceLength
                cursor = piece.end
            }
        }
        return cursor
    }

    /// UTF-16 offset where speech should resume so it starts at a sentence
    /// boundary instead of mid-word: the start of the sentence containing
    /// `charsDone`, applying the same boundary rules as `chunks(for:)`.
    /// Returns 0 when no earlier boundary exists — callers treat 0 as
    /// "restart from the beginning".
    ///
    /// - Parameters:
    ///   - text: The full text playback was started with.
    ///   - charsDone: UTF-16 character count already spoken.
    public static func resumeOffset(in text: String, charsDone: Int) -> Int {
        guard !text.isEmpty, charsDone > 0 else { return 0 }
        return sentencePieces(in: text).last(where: { charsDone >= $0.offset })?.offset ?? 0
    }

    /// Sentence-aligned playback pieces: UNPACKED (one piece ≈ one sentence,
    /// oversized sentences word-split at `maxChars`), as UTF-16 spans that
    /// cover the text exactly. This is the source of truth for both resume
    /// offsets and read-along highlighting — do NOT use `chunks(for:)` for
    /// either: it packs consecutive sentences into batches, which made the
    /// highlight (and once the resume) jump across whole batches.
    ///
    /// A piece carries no boundary-byte information here — callers that paint
    /// a highlight use the whole documented Range API — so this stays a pure
    /// sentence walk. Its ONLY departure from `text`'s own structure is
    /// dropping pieces with nothing pronounceable in them (whitespace-only,
    /// punctuation-only), which would otherwise be handed to a synthesizer as
    /// empty text. A dropped piece leaves a visible gap, not a shifted offset:
    /// every returned offset is still an absolute UTF-16 position in `text`,
    /// exactly as before.
    public static func sentencePieces(in text: String, maxChars: Int = 200) -> [(offset: Int, endOffset: Int)] {
        guard !text.isEmpty, text.contains(where: { !$0.isWhitespace }) else { return [] }
        var result: [(offset: Int, endOffset: Int)] = []
        var cursor = text.startIndex
        // Running UTF-16 offset — avoids recomputing `text[..<piece.start].utf16.count`
        // per piece, which was O(n²) on the resume/read-along hot path.
        var runningOffset = 0
        while cursor < text.endIndex {
            let end = sentenceEnd(in: text, from: cursor, limit: text.endIndex) ?? text.endIndex
            for piece in splitOversized(text, start: cursor, end: end, maxUtf16: max(1, maxChars)) {
                let pieceLength = text[piece.start..<piece.end].utf16.count
                result.append((offset: runningOffset, endOffset: runningOffset + pieceLength))
                runningOffset += pieceLength
            }
            cursor = end
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
