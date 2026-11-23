//
//  SelectionOffsetMapper.swift
//  SpeechLogic
//
//  Maps a selection made in a RENDERED surface onto the same place in the
//  text the SPEECH engine reads.
//
//  Why this exists: the reader surfaces and the engine do not read the same
//  string. A book's web reader hands over the DOM's own block text (soft
//  wrapped lines, tabs, non-breaking spaces, entities already decoded), the
//  note preview hands over text it built from the markdown AST, and the
//  engine reads the chapter's EXTRACTED — and sanitised — text. The three
//  carry the same words but never the same bytes, so "start reading here"
//  cannot be a byte offset copied across.
//
//  The mapper therefore normalises whitespace on BOTH sides while recording
//  where every normalised character came from, finds the block inside the
//  speech text, adds the intra-block offset, and maps the result back onto
//  the ORIGINAL speech offset. Whitespace is the only difference it can
//  bridge safely: it never reorders, drops or rewrites a word.
//
//  Pure string work by design — it lives in the SpeechLogic package, so the
//  logic-tests job in CI exercises it on every push.
//

import Foundation

/// Maps a selection in a rendered surface onto an offset in the speech text.
public enum SelectionOffsetMapper {

    /// The speech offset of a selection's START.
    ///
    /// - Parameters:
    ///   - blockText: the text of the block the selection sits in (the
    ///     paragraph / list item / DOM element the selection belongs to).
    ///   - blockOffset: the selection's start, as a UTF-16 offset into
    ///     `blockText`.
    ///   - speechText: the text the engine will speak.
    /// - Returns: the matching UTF-16 offset into `speechText`, or nil when
    ///   the block cannot be found in it (the caller then falls back to
    ///   searching the SELECTED text alone).
    public static func speechOffset(blockText: String, blockOffset: Int, speechText: String) -> Int? {
        guard blockOffset >= 0, blockOffset <= blockText.utf16.count else { return nil }
        let block = Normalized(blockText)
        let speech = Normalized(speechText)
        guard !block.text.isEmpty, !speech.text.isEmpty else { return nil }
        guard let match = speech.text.range(of: block.text) else { return nil }
        let matchStart = speech.text.distance(from: speech.text.startIndex, to: match.lowerBound)
        // The intra-block offset indexes the ORIGINAL block text; the
        // normalised text is what was searched, so the offset has to be
        // translated first (whitespace runs collapse, and a collapsed run
        // still occupies one position).
        let inner = block.normalizedIndex(atOrAfter: blockOffset)
        let target = matchStart + inner
        guard target >= 0, target < speech.map.count else { return nil }
        return speech.map[target]
    }

    /// The speech offset of a selected passage — the fallback for when the
    /// CONTAINING block cannot be found in the speech text (a deck's shape
    /// text, a PDF page's extracted prose, a block the extraction re-flowed).
    ///
    /// - Parameters:
    ///   - selectedText: the selected passage.
    ///   - speechText: the text the engine will speak.
    /// - Returns: the matching UTF-16 offset into `speechText`, or nil when
    ///   the passage does not occur in it.
    public static func speechOffset(selectedText: String, speechText: String) -> Int? {
        let selection = Normalized(selectedText)
        let speech = Normalized(speechText)
        guard !selection.text.isEmpty, !speech.text.isEmpty else { return nil }
        guard let match = speech.text.range(of: selection.text) else { return nil }
        let start = speech.text.distance(from: speech.text.startIndex, to: match.lowerBound)
        return speech.map[start]
    }

    // MARK: - Normalisation

    /// A whitespace-normalised string plus, for every normalised character,
    /// the UTF-16 offset it came from.
    ///
    /// The rules: every run of whitespace becomes ONE space, leading and
    /// trailing whitespace disappears, and nothing else is touched. The map
    /// has one extra trailing entry (the original's length) so an offset
    /// that sits at the very end of a block still resolves.
    private struct Normalized {
        let text: String
        /// `map[i]` = the UTF-16 offset in the ORIGINAL string of the i-th
        /// normalised character; `map[text.count]` = the original's length.
        let map: [Int]

        init(_ original: String) {
            var characters: [Character] = []
            var offsets: [Int] = []
            var cursor = 0
            var pendingSpace = false
            var spaceOrigin = 0
            var emittedAny = false
            for character in original {
                let start = cursor
                cursor += character.utf16.count
                if character.isWhitespace {
                    // A run of whitespace collapses into ONE space; the run
                    // carries no content, so it is anchored at the run's
                    // FIRST character — that keeps every later character's
                    // offset equal to its original one.
                    if emittedAny, !pendingSpace {
                        pendingSpace = true
                        spaceOrigin = start
                    }
                    continue
                }
                if pendingSpace {
                    characters.append(" ")
                    offsets.append(spaceOrigin)
                    pendingSpace = false
                }
                characters.append(character)
                offsets.append(start)
                emittedAny = true
            }
            self.text = String(characters)
            self.map = offsets + [original.utf16.count]
        }

        /// The index of the first normalised character that starts at or
        /// after the original UTF-16 `offset`. Binary search — `map` is
        /// non-decreasing.
        func normalizedIndex(atOrAfter offset: Int) -> Int {
            if offset <= 0 { return 0 }
            var low = 0
            var high = map.count - 1
            while low < high {
                let mid = (low + high) / 2
                if map[mid] < offset {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }
    }
}
