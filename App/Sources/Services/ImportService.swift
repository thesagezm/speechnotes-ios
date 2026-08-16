import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Imports text from files shared into the app (.txt, .md, .pdf).
///
/// LiveContainer can't host Share Extensions, so import flows through three
/// extension-free channels instead: the in-app Files picker, "Open In"
/// document-type registration (forwarded by LiveContainer or SideStore), and
/// the speechnotes:// URL scheme.
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
            return false
        }
        return acceptedContentTypes.contains { type.conforms(to: $0) }
    }

    /// Reads and extracts plain text. Call off the main thread — files can be
    /// large. Returns nil when nothing useful could be extracted.
    static func importText(from url: URL) -> (title: String, text: String)? {
        let scoped = url.startAccessingSecurityScopedResource()
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

    private static func plainText(from url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        if let latin = try? String(contentsOf: url, encoding: .isoLatin1) { return latin }
        return try? String(contentsOf: url)
    }

    private static func pdfText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        return document.string
    }
}
