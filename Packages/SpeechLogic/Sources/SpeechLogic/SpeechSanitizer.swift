//
//  SpeechSanitizer.swift
//  SpeechLogic
//
//  Cleans text so a TTS engine never chokes on it.
//
//  Why this exists: every engine in the app fails on *something* that came out
//  of a real document — Kokoro two-character embeddings go non-finite on an
//  empty phoneme tail, Supertonic's duration predictor returns a zero-length
//  result on stray control bytes, and both are handed text that still carries
//  what the file format used for layout rather than language: soft hyphens
//  used to break words across lines, zero-width joiners, BOMs, C1 control
//  bytes, private-use glyphs from embedded fonts, runs of forty blank lines.
//
//  The rule for this file: remove only characters a reader would NEVER
//  pronounce, and leave every one a reader would. No punctuation is touched —
//  the chunker's sentence rules and the read-along offsets both depend on it.
//  Everything here is a pure function.
//

import Foundation

/// Text hygiene for TTS: one pass that turns "the reader chokes on this"
/// into "the reader speaks it". Everything here is a pure function.
public enum SpeechSanitizer {

    // MARK: - Character classification

    /// Zero-width and formatting code points: invisible to a reader, but not
    /// to a tokenizer. Soft hyphen (U+00AD) is included — it is a *layout*
    /// hyphen, so leaving it in makes the engine pronounce a hyphen that the
    /// page never showed.
    private static let zeroWidth: Set<Unicode.Scalar> = [
        0x00AD, // soft hyphen (layout hyphen)
        0x200B, // zero width space
        0x200C, // zero width non-joiner
        0x200D, // zero width joiner
        0x200E, // left-to-right mark
        0x200F, // right-to-left mark
        0x2060, // word joiner
        0x2061, 0x2062, 0x2063, 0x2064, // invisible operators
        0xFEFF, // BOM / zero width no-break space
    ]

    /// Bidi embedding/override controls (U+202A–U+202E) and isolates
    /// (U+2066–U+2069). Not unpronounceable in principle, but an engine that
    /// honours them can reverse a line's phoneme order, and a document that
    /// carries them usually means them as layout.
    private static let bidiControls: Set<Unicode.Scalar> = [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    /// Variation selectors (emoji presentation, CJK ideographic variation).
    private static let variationSelectors: ClosedRange<Unicode.Scalar> = 0xFE00...0xFE0F
    private static let variationSelectorsSupplement: ClosedRange<Unicode.Scalar> = 0xE0100...0xE01EF

    /// Private Use Area — glyphs from an embedded font with no agreed
    /// pronunciation anywhere (the "tofu box" of TTS).
    private static let privateUse: [ClosedRange<Unicode.Scalar>] = [
        0xE000...0xF8FF,
        0xF0000...0xFFFFD,
        0x100000...0x10FFFD,
    ]

    // MARK: - Public API

    /// Strips what a reader cannot pronounce and tidies the whitespace left
    /// behind, preserving paragraph structure.
    ///
    /// - Parameter text: Raw text from any source (editor paste, file import,
    ///   extracted EPUB/PDF chapter, audiobook sidecar).
    /// - Returns: The same text with unpronounceable code points removed and
    ///   whitespace runs normalised. Line breaks between non-empty lines are
    ///   kept — the chunker treats them as sentence boundaries — and three or
    ///   more consecutive newlines collapse to one blank line.
    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if isUnspeakable(scalar) { continue }
            out.append(scalar)
        }
        return normalizeWhitespace(String(out))
    }

    /// True when the scalar has no business reaching a speech engine:
    /// C0/C1 controls except tab and newline, zero-width and bidi controls,
    /// variation selectors, private-use glyphs. Cells of the Basic
    /// Multilingual Plane that are unassigned are *kept* — Unicode's own
    /// convention (U+FFFD) is a better signal than a guess here.
    public static func isUnspeakable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00:
            return scalar != "\t" && scalar != "\n" && scalar != "\r"
        case 0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F:
            return true
        default:
            break
        }
        if zeroWidth.contains(scalar) { return true }
        if bidiControls.contains(scalar) { return true }
        if variationSelectors.contains(scalar) { return true }
        if variationSelectorsSupplement.contains(scalar) { return true }
        for range in privateUse where range.contains(scalar) { return true }
        return false
    }

    /// Offset-preserving variant of `clean(_:)` for paths that index the
    /// cleaned string with offsets taken from the ORIGINAL text — the read-along
    /// highlight is exactly that, and dropping characters there would slide
    /// every later highlight.
    ///
    /// Unpronounceable scalars are replaced by a single space rather than
    /// removed. A space is the one substitution that is safe on both sides of
    /// the pipeline: it is a legal chunk boundary for the sentence scanner, and
    /// it is invisible to the reader, so a page full of soft hyphens and
    /// joiners stops breaking synthesis without moving a single later offset.
    ///
    /// Length is preserved exactly: `result.utf16.count == text.utf16.count`.
    /// Control characters that a reader would treat as a line break (CR, and
    /// the Unicode line/paragraph separators) become `\n`; every other
    /// unspeakable scalar becomes a space.
    public static func cleanedPreservingOffsets(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if isUnspeakable(scalar) {
                out.append(scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" ? "\n" : " ")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Collapses whitespace runs while preserving paragraph structure:
    /// CRLF/CR become LF, trailing spaces go, and 3+ newlines become one
    /// blank line. Idempotent — `clean(clean(x)) == clean(x)`.
    public static func normalizeWhitespace(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var lines: [String] = []
        lines.reserveCapacity(64)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine
            if line.hasSuffix("\r") { line = line.dropLast() }
            lines.append(collapseSpaces(in: line))
        }

        // Trim leading/trailing blank lines, collapse 3+ to 2.
        var start = 0
        while start < lines.count, lines[start].isEmpty { start += 1 }
        var end = lines.count
        while end > start, lines[end - 1].isEmpty { end -= 1 }
        guard start < end else { return "" }

        var out: [String] = []
        out.reserveCapacity(end - start)
        var blankRun = 0
        for index in start..<end {
            let line = lines[index]
            if line.isEmpty {
                blankRun += 1
                if blankRun < 2 { out.append(line) }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// The substring around `offset` that a speech engine is handed, grown to
    /// word boundaries so a page/paragraph boundary landing mid-word does not
    /// cut one. Used by the audiobook sidecar builder, where a segment's char
    /// span comes from the file's own metadata and can point anywhere.
    ///
    /// - Parameters:
    ///   - text: The full text the offsets index into.
    ///   - offset: UTF-16 start offset of the wanted span.
    ///   - length: UTF-16 length of the wanted span.
    ///   - slack: How far past each edge the boundary search may reach.
    /// - Returns: A substring whose UTF-16 offsets are `startOffset..<endOffset`
    ///   in `text`.
    public static func snappedSpan(
        in text: String,
        offset: Int,
        length: Int,
        slack: Int = 200
    ) -> (startOffset: Int, endOffset: Int, text: String) {
        let units = Array(text.utf16)
        let total = units.count
        let start = min(max(0, offset), total)
        let end = min(max(start, start + length), total)
        let snappedStart = precedingWordBoundary(units: units, from: start, limit: max(0, start - slack))
        let snappedEnd = followingWordBoundary(units: units, from: end, limit: min(total, end + slack))
        let slice = Array(units[snappedStart..<snappedEnd])
        return (snappedStart, snappedEnd, String(decoding: slice, as: UTF16.self))
    }

    // MARK: - Private

    /// True for the whitespace a reader treats as a space (not newlines).
    private static func isSpaceUnit(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0C || unit == 0x0B
            || unit == 0xA0 || unit == 0x1680 || (0x2000...0x200A).contains(unit)
            || unit == 0x2028 || unit == 0x2029 || unit == 0x202F || unit == 0x205F || unit == 0x3000
    }

    /// Collapses every run of space-like characters to one ASCII space and
    /// trims the ends. Newlines never reach here (callers split on them).
    private static func collapseSpaces(in line: Substring) -> String {
        guard !line.isEmpty else { return "" }
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var wroteAny = false
        for scalar in line.unicodeScalars {
            if scalar == "\t" || scalar == "\u{A0}" || scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, wroteAny { out.append(" ") }
            pendingSpace = false
            wroteAny = true
            out.append(scalar)
        }
        return String(out)
    }

    /// Walks backwards from `from` to the first whitespace, returning the
    /// offset just after it; stops at `limit`. Falls back to `from`.
    private static func precedingWordBoundary(units: [UInt16], from: Int, limit: Int) -> Int {
        guard from > 0 else { return 0 }
        var index = from
        while index > limit, index > 0 {
            if isSpaceUnit(units[index - 1]) { return index }
            index -= 1
        }
        return from
    }

    /// Walks forwards from `from` to the first whitespace, returning the
    /// offset just before it; stops at `limit`. Falls back to `from`.
    private static func followingWordBoundary(units: [UInt16], from: Int, limit: Int) -> Int {
        guard from < units.count else { return units.count }
        var index = from
        while index < limit {
            if isSpaceUnit(units[index]) { return index }
            index += 1
        }
        return from
    }
}