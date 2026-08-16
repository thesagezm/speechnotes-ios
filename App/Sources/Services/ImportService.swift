import Foundation
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
    static var acceptedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .utf8PlainText]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let markdownAlt = UTType(filenameExtension: "markdown") { types.append(markdownAlt) }
        return types
    }

    static func canImport(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let pathExtension = url.pathExtension.lowercased()
        if ["txt", "text", "md", "markdown", "pdf"].contains(pathExtension) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            // No extension and no type metadata — let the reader decide.
            return pathExtension.isEmpty
        }
        return acceptedContentTypes.contains { type.conforms(to: $0) }
    }

    /// Reads and extracts plain text. Call off the main thread — files can be
    /// large, and iCloud downloads can take seconds. Returns nil (with a
    /// logged reason) when nothing useful could be extracted.
    static func importText(from url: URL) -> (title: String, text: String)? {
        Log.shared.info("ImportService: reading \(url.lastPathComponent)")
        let scoped = url.startAccessingSecurityScopedResource()
        Log.shared.info("ImportService: security scope granted = \(scoped)")
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let title = url.deletingPathExtension().lastPathComponent
        let kind = url.pathExtension.lowercased()

        let text = kind == "pdf" ? pdfText(from: url) : plainText(from: url)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.shared.error("ImportService: no extractable text in \(url.lastPathComponent)")
            return nil
        }
        Log.shared.info("ImportService: imported \(url.lastPathComponent) (\(text.count) chars, \(kind.isEmpty ? "text" : kind))")
        return (title.isEmpty ? "Imported note" : String(title.prefix(60)), text)
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
    /// materialize the file if it's an un-downloaded ubiquitous item.
    private static func coordinatedData(from url: URL) -> Data? {
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

        var readData: Data?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                readData = try Data(contentsOf: readURL, options: .mappedIfSafe)
            } catch {
                Log.shared.error("ImportService: read error: \(error.localizedDescription)")
            }
        }
        if let coordinationError {
            Log.shared.error("ImportService: file coordination error: \(coordinationError.localizedDescription)")
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

    private static func pdfText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        return document.string
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
