import Foundation
import PDFKit

/// One speech unit of a PDF: `startPage...endPage` (inclusive). Persisted in
/// the book manifest (`Book.pdfChapters`) so library, reader and TTS agree
/// without re-parsing the document. Hashable so Book keeps its synthesized
/// Hashable conformance (NavigationLink(value:)).
public struct PdfChapter: Codable, Equatable, Hashable {
    public var label: String
    public var startPage: Int
    public var endPage: Int

    public init(label: String, startPage: Int, endPage: Int) {
        self.label = label
        self.startPage = startPage
        self.endPage = endPage
    }
}

/// Where a page's text starts inside its chapter's speech text — the
/// read-along page-sync sidecar (`text/NNNN.pages.json`).
public struct PdfPageOffset: Codable, Equatable, Hashable {
    public var page: Int
    public var utf16Offset: Int

    public init(page: Int, utf16Offset: Int) {
        self.page = page
        self.utf16Offset = utf16Offset
    }
}

/// PDF → speech-text logic. The PDF's outline tree IS its chapter list; when
/// a PDF has none, headings are detected from line geometry (a heading line is
/// significantly taller than the modal body line — the geometric sibling of
/// the classic font-size heuristic), and labeled page ranges are the floor so
/// playback ALWAYS has navigable units.
///
/// Costs and pitfalls this file is built around (researched 2026-09-06):
/// whole-document `PDFDocument.string` freezes large PDFs — extraction is per
/// page, cached by the caller, off-main. Ligatures (ﬁ, ﬂ) must be NFKC-mapped
/// before chunking or the engine hears one glyph per word-part. ISO 32000
/// defines no reading order, so two-column pages need a gutter split.
///
/// Written to the PDFKit API subset that is identical on macOS 13 (logic
/// tests + pdf-spike) and iOS 18: numberOfChildren/child(at:) — this SDK's
/// PDFOutline has no `.children` array (CI-caught during v1.4.2) — plus
/// PDFPage.string/selection(for:)/bounds(for:) and PDFDocument.index(for:).
public enum PdfText {
    // MARK: - Chapter resolution (outline → headings → page ranges)

    /// The one entry the app calls. Returns the chapter list and where it
    /// came from (persisted as `Book.pdfChapterSource` for diagnostics).
    public static func resolveChapters(in document: PDFDocument) -> (chapters: [PdfChapter], source: String) {
        if let chapters = chaptersFromOutline(of: document) {
            return (chapters, "outline")
        }
        if let chapters = chaptersFromHeadings(in: document) {
            return (chapters, "headings")
        }
        return (fallbackChapters(pageCount: document.pageCount), "pages")
    }

    /// Top-level outline nodes as chapter starts. A node with a resolvable
    /// destination contributes ONE start and its children are swallowed (a
    /// "Part II" node pointing at its own first page must not also emit every
    /// section under it); a node without a destination defers to its children.
    /// Starts are then fixed up to be strictly increasing and non-empty.
    public static func chaptersFromOutline(of document: PDFDocument) -> [PdfChapter]? {
        let pageCount = document.pageCount
        guard pageCount > 0, let root = document.outlineRoot, root.numberOfChildren > 0 else {
            return nil
        }
        var starts: [(label: String, page: Int)] = []
        func walk(_ outline: PDFOutline) {
            if let destination = outline.destination, let page = destination.page {
                let index = document.index(for: page)
                let label = (outline.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if index >= 0, index < pageCount, !label.isEmpty {
                    starts.append((label, index))
                }
            } else {
                for childIndex in 0..<outline.numberOfChildren {
                    if let child = outline.child(at: childIndex) {
                        walk(child)
                    }
                }
            }
        }
        for childIndex in 0..<root.numberOfChildren {
            if let child = root.child(at: childIndex) {
                walk(child)
            }
        }
        // Monotonic fix-up: outlines frequently contain repeats and back
        // references; only strictly-increasing starts make page ranges work.
        var kept: [(label: String, page: Int)] = []
        for start in starts where kept.last?.page ?? -1 < start.page {
            kept.append(start)
        }
        guard kept.count >= 2 else { return nil }
        var chapters: [PdfChapter] = []
        for (position, start) in kept.enumerated() {
            let end = position + 1 < kept.count ? kept[position + 1].page - 1 : pageCount - 1
            guard end >= start.page else { continue }
            chapters.append(PdfChapter(label: start.label, startPage: start.page, endPage: end))
        }
        // Cover/title pages before the first bookmark still need to be
        // reachable — one front-matter unit at the front.
        if let firstStart = chapters.first?.startPage, firstStart > 0 {
            chapters.insert(
                PdfChapter(label: "Front matter", startPage: 0, endPage: firstStart - 1),
                at: 0
            )
        }
        return chapters
    }

    /// No outline: detect headings from line geometry. Per page the lines'
    /// heights are collected; the modal height is the body size; a SHORT line
    /// at least 1.25× the modal height starts a chapter. Second heading on
    /// the SAME page is swallowed (page-granular units). Bounded by
    /// `maxScanPages` so a 1000-page scan dump falls through to page ranges
    /// instead of grinding.
    public static func chaptersFromHeadings(in document: PDFDocument, maxScanPages: Int = 400) -> [PdfChapter]? {
        let pageCount = document.pageCount
        guard pageCount > 1 else { return nil }
        let scanLimit = min(pageCount, maxScanPages)

        var heights: [Double] = []
        var candidates: [(page: Int, label: String)] = []
        for pageIndex in 0..<scanLimit {
            guard let page = document.page(at: pageIndex) else { continue }
            let lines = lines(of: page)
            for line in lines {
                heights.append(Double(line.height))
            }
        }
        guard let bodyHeight = modalValue(of: heights), bodyHeight > 0 else { return nil }

        for pageIndex in 0..<scanLimit {
            guard let page = document.page(at: pageIndex) else { continue }
            for line in lines(of: page)
            where Double(line.height) >= bodyHeight * 1.25 && line.text.count < 80 {
                if candidates.last?.page != pageIndex {
                    candidates.append((pageIndex, line.text))
                }
            }
        }
        guard candidates.count >= 2 else { return nil }

        var chapters: [PdfChapter] = []
        // Front matter before the first detected heading stays playable.
        if let first = candidates.first, first.page > 0 {
            chapters.append(PdfChapter(label: "Front matter", startPage: 0, endPage: first.page - 1))
        }
        for (position, candidate) in candidates.enumerated() {
            let end = position + 1 < candidates.count ? candidates[position + 1].page - 1 : pageCount - 1
            guard end >= candidate.page else { continue }
            chapters.append(PdfChapter(label: candidate.label, startPage: candidate.page, endPage: end))
        }
        return chapters.count >= 2 ? chapters : nil
    }

    /// The floor: fixed page groups so playback always has navigable units.
    public static func fallbackChapters(pageCount: Int, groupSize: Int = 10) -> [PdfChapter] {
        guard pageCount > 0 else { return [] }
        var chapters: [PdfChapter] = []
        var start = 0
        while start < pageCount {
            let end = min(start + groupSize - 1, pageCount - 1)
            chapters.append(
                PdfChapter(label: "Pages \(start + 1)–\(end + 1)", startPage: start, endPage: end)
            )
            start = end + 1
        }
        return chapters
    }

    // MARK: - Page text (columns + normalization)

    /// One rendered text line and where it sits on the page (page space —
    /// the same coordinates `PDFPage.selection(for:)` and `bounds(for:)` use).
    public struct Line {
        public let text: String
        public let x: CGFloat
        public let y: CGFloat
        public let width: CGFloat
        public let height: CGFloat
    }

    public static func lines(of page: PDFPage) -> [Line] {
        let pageBounds = page.bounds(for: .mediaBox)
        guard let pageSelection = page.selection(for: pageBounds) else { return [] }
        var result: [Line] = []
        for lineSelection in pageSelection.selectionsByLine() {
            let text = (lineSelection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let bounds = lineSelection.bounds(for: page)
            result.append(
                Line(
                    text: text,
                    x: bounds.origin.x,
                    y: bounds.origin.y,
                    width: bounds.width,
                    height: bounds.height
                )
            )
        }
        return result
    }

    /// Extracts one page for TTS. Two-column layouts are split at a detected
    /// gutter and read left→right (PDFKit's default order interleaves the
    /// columns); everything else uses the page's default string.
    public static func pageText(_ page: PDFPage) -> String {
        let lines = lines(of: page)
        if let split = columnSplit(page: page, lines: lines) {
            let left = page.selection(for: split.left)?.string ?? ""
            let right = page.selection(for: split.right)?.string ?? ""
            if !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalize(left) + "\n\n" + normalize(right)
            }
        }
        return normalize(page.string ?? "")
    }

    /// Gutter detection for real pages: the line-geometry scan first, then a
    /// selection probe for pages where PDFKit's line grouping merges or spans
    /// the columns (running heads, equations, tight measures).
    public static func columnSplit(page: PDFPage, lines: [Line]) -> (left: CGRect, right: CGRect)? {
        guard lines.count >= 6 else { return nil }
        let pageBounds = page.bounds(for: .mediaBox)
        return twoColumnSplit(pageBounds: pageBounds, lines: lines)
            ?? probedGutter(page: page, pageBounds: pageBounds)
    }

    /// A page carries a text layer only if it yields real characters —
    /// scanned pages return whitespace-level output and must go to OCR.
    public static func pageHasTextLayer(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count >= 16
    }

    /// Finds a vertical gutter that cleanly separates two text columns: a
    /// narrow band down the middle third of the page that NO line crosses,
    /// with real text on both sides. Returns mediaBox-space rects for the
    /// left and right column content.
    public static func twoColumnSplit(pageBounds: CGRect, lines: [Line]) -> (left: CGRect, right: CGRect)? {
        guard !lines.isEmpty else { return nil }
        let width = pageBounds.width
        guard width > 0, lines.count >= 6 else { return nil }

        func crossingCount(_ band: ClosedRange<CGFloat>) -> Int {
            lines.filter { $0.x < band.upperBound && $0.x + $0.width > band.lowerBound }.count
        }

        let bandWidth = width * 0.03
        var best: (start: CGFloat, end: CGFloat, crossings: Int)?
        var cursor = pageBounds.minX + width * 0.25
        let limit = pageBounds.minX + width * 0.75
        while cursor + bandWidth <= limit {
            let band = cursor...(cursor + bandWidth)
            let crossings = crossingCount(band)
            if crossings == 0, best == nil {
                best = (cursor, cursor + bandWidth, 0)
            }
            cursor += bandWidth
        }
        guard let gutter = best else { return nil }

        let leftLines = lines.filter { $0.x + $0.width <= gutter.start }.count
        let rightLines = lines.filter { $0.x >= gutter.end }.count
        guard leftLines >= max(2, lines.count / 5), rightLines >= max(2, lines.count / 5) else {
            return nil
        }
        let left = CGRect(
            x: pageBounds.minX,
            y: pageBounds.minY,
            width: gutter.start - pageBounds.minX,
            height: pageBounds.height
        )
        let right = CGRect(
            x: gutter.end,
            y: pageBounds.minY,
            width: pageBounds.maxX - gutter.end,
            height: pageBounds.height
        )
        return (left, right)
    }

    /// Selection-probe gutter for real-world pages: a candidate band IS the
    /// gutter when the page yields NO text inside it (top/bottom margins
    /// excluded so running heads and page numbers can't veto a true gutter)
    /// while both halves carry real text. Costs one selection per candidate
    /// band, and only runs when the geometry scan found nothing.
    private static func probedGutter(page: PDFPage, pageBounds: CGRect) -> (left: CGRect, right: CGRect)? {
        let width = pageBounds.width
        let height = pageBounds.height
        guard width > 0, height > 0 else { return nil }
        let contentY = pageBounds.minY + height * 0.06
        let contentHeight = height * 0.88
        let bandWidth = width * 0.012
        var cursor = pageBounds.minX + width * 0.30
        let limit = pageBounds.minX + width * 0.70
        while cursor + bandWidth <= limit {
            let band = CGRect(x: cursor, y: contentY, width: bandWidth, height: contentHeight)
            let bandText = (page.selection(for: band)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if bandText.isEmpty {
                let left = CGRect(
                    x: pageBounds.minX, y: contentY,
                    width: cursor - pageBounds.minX, height: contentHeight
                )
                let right = CGRect(
                    x: cursor + bandWidth, y: contentY,
                    width: pageBounds.maxX - (cursor + bandWidth), height: contentHeight
                )
                let leftText = (page.selection(for: left)?.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rightText = (page.selection(for: right)?.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if leftText.count >= 40, rightText.count >= 40 {
                    return (left, right)
                }
            }
            cursor += bandWidth
        }
        return nil
    }

    /// One chapter's speech text, built page by page (the caller caches the
    /// result to `text/NNNN.txt` — replay/resume never re-extracts). Also
    /// returns where each page's text starts (UTF-16) so read-along can
    /// auto-scroll the PDFView to the sounding page.
    public static func chapterText(
        in document: PDFDocument,
        chapters: [PdfChapter],
        index: Int
    ) -> (text: String, pageOffsets: [PdfPageOffset])? {
        guard index >= 0, index < chapters.count else { return nil }
        let chapter = chapters[index]
        var text = ""
        var pageOffsets: [PdfPageOffset] = []
        for pageNumber in chapter.startPage...chapter.endPage {
            guard pageNumber >= 0, pageNumber < document.pageCount,
                  let page = document.page(at: pageNumber) else { continue }
            let pageString = pageText(page)
            guard !pageString.isEmpty else { continue }
            pageOffsets.append(PdfPageOffset(page: pageNumber, utf16Offset: text.utf16.count))
            if !text.isEmpty { text += "\n\n" }
            text += pageString
        }
        guard !text.isEmpty else { return nil }
        return (text, pageOffsets)
    }

    // MARK: - Normalization

    /// NFKC maps ligatures (ﬁ → fi, ﬂ → fl) and other compatibility forms so
    /// the engine hears spelled-out text; hyphen-newline joins words split
    /// across lines ("exam-\nple" → "example"); CR/PDFKit line endings become
    /// plain \n with blank runs collapsed to one paragraph break.
    public static func normalize(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        for hyphenBreak in ["-\r\n", "-\r", "-\n"] {
            while text.range(of: hyphenBreak) != nil {
                text = text.replacingOccurrences(of: hyphenBreak, with: "")
            }
        }
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text
    }

    // MARK: - Helpers

    /// Modal value via 1-D clustering: sort, grow clusters while values stay
    /// within `bucket` of the cluster's first member, take the biggest
    /// cluster's midpoint — line heights jitter by fractions of a point, so
    /// exact-equality histograms never peak.
    private static func modalValue(of values: [Double], bucket: Double = 1.5) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        var bestCount = 0
        var bestValue = sorted[0]
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] - sorted[index] <= bucket {
                end += 1
            }
            let count = end - index + 1
            if count > bestCount {
                bestCount = count
                bestValue = (sorted[index] + sorted[end]) / 2
            }
            index = end + 1
        }
        return bestValue
    }
}
