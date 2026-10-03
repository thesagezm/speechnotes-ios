import Foundation
import SwiftUI

/// Which text extractor produces a PDF's speech text.
///
/// The built-in path is PDFKit: fast, no extra machinery, and good enough for
/// a clean single-column document. Papero reconstructs reading order from glyph
/// geometry, so a two-column paper or a table-laden report comes out in the
/// order a human reads it — measurably better, and slower, and it needs a
/// webview and about 1.5 MB of vendored JavaScript to get there.
public enum PdfExtractionMode: String, CaseIterable, Identifiable, Sendable {
    /// PDFKit only. The fastest path, and the one to keep for a big scanned
    /// book where extraction time is the whole cost.
    case builtin
    /// Papero only. A failure is a failure — no silent downgrade, so this is
    /// the mode to use when you are checking a document's fidelity.
    case papero
    /// Papero, falling back to PDFKit when papero cannot serve the document
    /// (a scanned page set, an encrypted or malformed file, a webview that
    /// refuses to load). The setting most people should leave it on.
    case automatic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builtin: return "Built-in"
        case .papero: return "Papero"
        case .automatic: return "Automatic"
        }
    }

    public var blurb: String {
        switch self {
        case .builtin:
            return "Fast and offline. Best for plain single-column documents."
        case .papero:
            return "Most accurate reading order for columns, tables and headings. Slower."
        case .automatic:
            return "Papero where it helps, built-in when it can't. Recommended."
        }
    }

    /// True when papero is worth attempting before falling back.
    public var prefersPapero: Bool {
        self == .papero || self == .automatic
    }

    // MARK: - Storage

    private static let key = "pdfExtractionMode"

    /// The user's choice, defaulting to `automatic`.
    public static var current: PdfExtractionMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .automatic }
            return PdfExtractionMode(rawValue: raw) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Settings → a picker for the extractor, with each level's trade-off spelled
/// out rather than left to be discovered by a bad extraction.
struct PdfExtractionModePicker: View {
    @Binding private var mode: PdfExtractionMode

    init(mode: Binding<PdfExtractionMode>) {
        _mode = mode
    }

    var body: some View {
        Picker("PDF text extraction", selection: $mode) {
            ForEach(PdfExtractionMode.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
}

struct PdfExtractionModeBlurb: View {
    let mode: PdfExtractionMode

    var body: some View {
        Text(mode.blurb)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
