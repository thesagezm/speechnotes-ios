import Foundation

/// The book reader's appearance settings, persisted in UserDefaults under
/// the `bookReader*` key family (BookReaderView's @AppStorage properties
/// share these exact keys — the sheet writes through @AppStorage, the
/// webview shell reads through load()).
///
/// One struct, not loose parameters: the shell URL query and the live JS
/// bridge both need the FULL current state on every reload/appearance
/// change, and a struct keeps both encodings (query items, JSON) in one
/// place. Codable field names double as the JSON keys the reader.js
/// `readerAppearance({...})` command consumes — don't rename casually.
struct ReaderAppearance: Codable {
    /// light | sepia | dark | trueBlack
    var theme: String
    /// Percent, 70...200.
    var fontSize: Int
    /// scrolled | paginated
    var flow: String
    /// book | serif | sans | mono ("book" = leave the publisher's font alone)
    var font: String
    /// 1.2...2.5
    var lineHeight: Double
    /// em added below paragraphs, 0...2
    var paraSpacing: Double
    /// px, 0...3
    var letterSpacing: Double
    /// px padding around the page, 0...48. Scrolled flow only — epub.js
    /// computes paginated column widths from the container, and padding
    /// there breaks the column math.
    var margin: Int
    /// When true only theme colors are applied; the book's own CSS keeps
    /// typography control (Anx's "use book styles" switch).
    var respectStyles: Bool
    var autoScroll: Bool
    /// px/s, 10...200
    var autoScrollSpeed: Double
    // Page-turn interaction (v1.7.2, Anx-style choice). Tap zones and swipe
    // only act in paginated flow — scrolled flow is native scrolling.
    var tapTurn: Bool
    var swipeTurn: Bool
    /// Swap left/right tap zones (RTL readers).
    var tapInverted: Bool

    static let defaults = ReaderAppearance(
        theme: "light",
        fontSize: 100,
        flow: "scrolled",
        font: "book",
        lineHeight: 1.6,
        paraSpacing: 0,
        letterSpacing: 0,
        margin: 16,
        respectStyles: false,
        autoScroll: false,
        autoScrollSpeed: 40,
        tapTurn: true,
        swipeTurn: true,
        tapInverted: false
    )

    var flowIsPaginated: Bool { flow == "paginated" }

    /// Reads the current values from UserDefaults.
    static func load(_ d: UserDefaults = .standard) -> ReaderAppearance {
        var a = defaults
        a.theme = d.string(forKey: "bookReaderTheme") ?? a.theme
        let size = d.double(forKey: "bookReaderFontSize")
        if size > 0 { a.fontSize = Int(size) }
        a.flow = d.string(forKey: "bookReaderFlow") ?? a.flow
        a.font = d.string(forKey: "bookReaderFont") ?? a.font
        let lh = d.double(forKey: "bookReaderLineHeight")
        if lh > 0 { a.lineHeight = lh }
        a.paraSpacing = d.double(forKey: "bookReaderParaSpacing")
        a.letterSpacing = d.double(forKey: "bookReaderLetterSpacing")
        let margin = d.object(forKey: "bookReaderMargin") as? Int
        if let margin { a.margin = margin }
        a.respectStyles = d.bool(forKey: "bookReaderRespectStyles")
        a.autoScroll = d.bool(forKey: "bookReaderAutoScroll")
        let speed = d.double(forKey: "bookReaderAutoScrollSpeed")
        if speed > 0 { a.autoScrollSpeed = speed }
        // Booleans defaulting to TRUE must distinguish "unset" from false —
        // bool(forKey:) answers false for a missing key.
        a.tapTurn = (d.object(forKey: "bookReaderTapTurn") as? Bool) ?? true
        a.swipeTurn = (d.object(forKey: "bookReaderSwipeTurn") as? Bool) ?? true
        a.tapInverted = d.bool(forKey: "bookReaderTapInverted")
        return a
    }

    /// Query items for the shell URL — the initial state rides the URL so
    /// it applies at rendition creation (later pushes would race it, the
    /// same reason theme/fontSize have always ridden the URL).
    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "theme", value: theme),
            URLQueryItem(name: "fontSize", value: String(fontSize)),
            URLQueryItem(name: "flow", value: flow),
            URLQueryItem(name: "font", value: font),
            URLQueryItem(name: "lineHeight", value: String(lineHeight)),
            URLQueryItem(name: "paraSpacing", value: String(paraSpacing)),
            URLQueryItem(name: "letterSpacing", value: String(letterSpacing)),
            URLQueryItem(name: "padding", value: String(margin)),
            URLQueryItem(name: "respectStyles", value: respectStyles ? "1" : "0"),
            URLQueryItem(name: "tapTurn", value: tapTurn ? "1" : "0"),
            URLQueryItem(name: "swipeTurn", value: swipeTurn ? "1" : "0"),
            URLQueryItem(name: "tapInv", value: tapInverted ? "1" : "0"),
        ]
    }

    /// The live-apply JS command: `readerAppearance({...})`.
    var jsCommand: String {
        let data = try! JSONEncoder().encode(self)
        return "readerAppearance(" + String(data: data, encoding: .utf8)! + ")"
    }
}
