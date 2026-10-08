import Foundation
import SpeechLogic
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Imports text from files shared into the app (.txt, .md, .pdf).
///
/// LiveContainer can't host Share Extensions, so import flows through
/// extension-free channels instead: the in-app Files picker, drag & drop
/// onto the notes list, "New note from clipboard", "Open In" document-type
/// registration (forwarded by LiveContainer or SideStore where supported),
/// and the speechnotes:// URL scheme.
///
/// Reading is deliberately defensive — the historical "import doesn't work"
/// reports came from two silent failure modes this now handles and logs:
/// iCloud files that aren't materialized on device yet, and non-UTF-8
/// (Windows/latin-1) text files. Every step logs so device reports pinpoint
/// the exact failure.
final class ImportService {
    private init() {}

    /// File types we accept, for the Files picker and Open-In registration.
    /// Built on the broad `.text` base instead of dynamic `UTType(filenameExtension:)`
    /// lookups — dynamic types for md/markdown proved unreliable in the
    /// fileImporter on device (files greyed out or silently unselectable),
    /// while `.text` covers txt/md/markdown and friends.
    static var acceptedContentTypes: [UTType] {
        [.pdf, .text]
    }

    static func canImport(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let pathExtension = url.pathExtension.lowercased()
        // Every document the Books shelf normalizes also makes an excellent
        // NOTE: the same chapters flatten to prose here, which is what a user
        // who drags an .azw3 onto the notes list expects.
        if pathExtension == "pdf" { return true }
        if DocumentBook.canNormalize(pathExtension) { return true }
        if pathExtension == "txt" || pathExtension == "text"
            || pathExtension == "md" || pathExtension == "markdown" {
            return true
        }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            // No extension and no type metadata (common before security scope
            // is granted) — let the reader decide; it fails with a log if the
            // file turns out to be unusable.
            return true
        }
        return acceptedContentTypes.contains { type.conforms(to: $0) }
    }

    /// Reads and extracts plain text. Call off the main thread — files can be
    /// large, and iCloud downloads can take seconds. Returns nil (with a
    /// logged reason) when nothing useful could be extracted.
    ///
    /// Async because the PDF branch reads whole documents. The security
    /// scope taken here stays open across that await — the `defer` below
    /// runs last.
    static func importText(from url: URL) async -> (title: String, text: String)? {
        Log.shared.info("ImportService: reading \(url.lastPathComponent)")
        let scoped = url.startAccessingSecurityScopedResource()
        Log.shared.info("ImportService: security scope granted = \(scoped)")
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let title = url.deletingPathExtension().lastPathComponent
        let kind = url.pathExtension.lowercased()

        let raw: String?
        switch kind {
        case "pdf":
            raw = await pdfText(from: url)
        case _ where DocumentBook.canNormalize(kind):
            // Every document format — the office set plus the mobipocket,
            // FictionBook, RTF, HTML and plain-text readers — flattens to the
            // same note text. ONE call site now, instead of a switch that had
            // to be extended at every import.
            raw = documentText(from: url, kind: kind)
        default:
            raw = plainText(from: url)
        }
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.shared.error("ImportService: no extractable text in \(url.lastPathComponent)")
            return nil
        }
        // Files arrive carrying whatever the producing app left in them — a
        // soft hyphen from a wrapped line, zero-width joiners, control bytes
        // from a broken export. Cleaning at import means the stored note is
        // speakable from the moment it lands, and the reader says exactly what
        // the user sees. DISPLAY-SAFE clean (2026-10-08): the stored note body
        // is content, not speech text — emoji the file carried (keycaps,
        // color circles, skin tones) must survive to the screen; the speech
        // path re-derives its own cleaned text at play time and never reads
        // the stored body as engine input.
        let text = SpeechSanitizer.displaySafe(raw)
        guard !text.isEmpty else {
            Log.shared.error("ImportService: \(url.lastPathComponent) had no speakable text after cleaning")
            return nil
        }
        Log.shared.info("ImportService: imported \(url.lastPathComponent) (\(text.count) chars, \(kind.isEmpty ? "text" : kind))")
        return (title.isEmpty ? "Imported note" : String(title.prefix(60)), text)
    }

    /// Any document format → speakable note text: parse, join paragraphs with
    /// blank lines (chapter structure is a Books-side concern; notes want
    /// prose). One dispatch for every format, so adding a reader means editing
    /// `DocumentBook` and nothing here.
    private static func documentText(from url: URL, kind: String) -> String? {
        guard let data = coordinatedData(from: url) else {
            Log.shared.error("ImportService: could not read \(kind) data from \(url.lastPathComponent)")
            return nil
        }
        do {
            let chapters = try DocumentBook.parse(fileExtension: kind, data: data).chapters
            let lines = chapters.flatMap { chapter -> [String] in
                var out: [String] = []
                if let title = chapter.title { out.append(title) }
                // textLines (not just paragraphs): table rows come through
                // as comma-joined lines, so nothing a document contains is
                // silently lost on the note path.
                out.append(contentsOf: chapter.textLines)
                return out
            }
            let joined = lines.joined(separator: "\n\n")
            Log.shared.info("ImportService: \(kind) parsed (\(lines.count) paragraphs)")
            return joined.isEmpty ? nil : joined
        } catch {
            Log.shared.error("ImportService: \(kind) parse failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Plain text

    /// Waits for iCloud materialization, reads via file coordination, then
    /// decodes with a battery of encodings.
    private static func plainText(from url: URL) -> String? {
        guard let data = coordinatedData(from: url) else {
            Log.shared.error("ImportService: could not read file data from \(url.lastPathComponent)")
            return nil
        }
        Log.shared.info("ImportService: read \(data.count) bytes")
        guard !data.isEmpty else { return nil }
        return decodeText(data)
    }

    /// Reads through `NSFileCoordinator`, and first asks iCloud to
    /// materialize the file if it's an un-downloaded ubiquitous item. The
    /// reader closure gets the coordinated URL and reads however it wants —
    /// by bytes (`coordinatedData`) or by lazily opening the document — so
    /// a big-file importer never has to hold the whole file in RAM.
    private static func coordinatedRead(from url: URL, _ reader: (URL) -> Void) {
        let fileManager = FileManager.default

        // iCloud Drive files can be placeholders; start the download and
        // wait (bounded) for the bytes to be local.
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            let downloaded = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus == .current
            if !downloaded {
                Log.shared.info("ImportService: iCloud file not local — downloading…")
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                        .ubiquitousItemDownloadingStatus == .current {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
        }

        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            reader(readURL)
        }
        if let coordinationError {
            Log.shared.error("ImportService: file coordination error: \(coordinationError.localizedDescription)")
        }
    }

    private static func coordinatedData(from url: URL) -> Data? {
        var readData: Data?
        coordinatedRead(from: url) { readURL in
            do {
                readData = try Data(contentsOf: readURL, options: .mappedIfSafe)
            } catch {
                Log.shared.error("ImportService: read error: \(error.localizedDescription)")
            }
        }
        return readData
    }

    /// UTF-8 first (with BOM variants), then UTF-16, then latin-1, and
    /// finally a lossy UTF-8 pass — anything non-empty beats failing.
    private static func decodeText(_ data: Data) -> String? {
        let candidates: [(String.Encoding, String)] = [
            (.utf8, "utf-8"),
            (.utf16LittleEndian, "utf-16le"),
            (.utf16BigEndian, "utf-16be"),
            (.utf32LittleEndian, "utf-32le"),
            (.utf32BigEndian, "utf-32be"),
            (.isoLatin1, "latin-1"),
        ]
        for (encoding, name) in candidates {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.shared.info("ImportService: decoded as \(name)")
                return text
            }
        }
        let lossy = String(decoding: data, as: UTF8.self)
        guard !lossy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        Log.shared.info("ImportService: decoded lossily as utf-8 (mixed/unknown encoding)")
        return lossy
    }

    // MARK: - PDF

    /// Caps so the note importer stays a note importer: per-page extraction
    /// (whole-document `PDFDocument.string` is the OOM/freeze pattern
    /// PdfText's own header bans) over at most `maxPdfPages` pages and
    /// `maxPdfTextChars` characters. A 500 MB textbook through this path
    /// used to be a jetsam kill; big books belong on the Books tab, which
    /// reads them lazily and by chapter.
    private static let maxPdfPages = 150
    private static let maxPdfTextChars = 1_000_000

    private static func pdfText(from url: URL) async -> String? {
        // PDFKit, off-main. The caps below are the note importer's own — a
        // note import is not a book import.
        let result = await PdfTextExtractor.text(
            for: url,
            maxPages: maxPdfPages,
            maxCharacters: maxPdfTextChars
        )
        if let result {
            Log.shared.info("ImportService: PDF text via pdfkit (\(result.text.utf16.count) chars)")
        }
        return result?.text
    }

    // MARK: - Clipboard

    /// Text currently on the pasteboard, if it looks like prose.
    static func clipboardText() -> String? {
        guard UIPasteboard.general.hasStrings,
              let text = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
