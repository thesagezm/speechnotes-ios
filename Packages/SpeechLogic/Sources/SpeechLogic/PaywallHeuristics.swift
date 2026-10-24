import Foundation

/// Decides, from fetched HTML (and how much text was actually extractable),
/// whether a page is showing a paywall rather than the article — the signal
/// that routes a web import through the Bypass Paywalls Clean pass instead
/// of accepting the truncated text.
///
/// Pure string work by design: it runs in the SpeechLogic package, so the
/// logic-tests job in CI exercises it on every push. High-precision markers
/// only — "subscribe to our newsletter" is on every free page on earth and
/// must NOT count. Every fired reason is logged on device so a wrong call
/// can be diagnosed from the import log.
public enum PaywallHeuristics {

    public struct Inspection: Equatable {

        /// True when at least one signal fired — treat the page's own text
        /// as paywalled/truncated and prefer the bypass pass's result.
        public let paywalled: Bool

        /// Which signals fired ("" for none) — surfaced in the import log.
        public let reasons: [String]

        public static let clean = Inspection(paywalled: false, reasons: [])
    }

    /// Phrases that appear in/around subscription walls. Matched
    /// case-insensitively against the whole HTML, so a single hit anywhere
    /// (overlay copy, JSON state, JSON-LD) counts.
    static let markerPhrases: [(String, String)] = [
        ("subscribe to continue", "marker: subscribe to continue"),
        ("subscribe to keep reading", "marker: subscribe to keep reading"),
        ("subscribe to read", "marker: subscribe to read"),
        ("subscription required", "marker: subscription required"),
        ("subscribers only", "marker: subscribers only"),
        ("subscriber-only", "marker: subscriber-only"),
        ("sign in to continue reading", "marker: sign in to continue reading"),
        ("log in to continue reading", "marker: log in to continue reading"),
        ("register to continue reading", "marker: register to continue reading"),
        ("create a free account to continue", "marker: create an account to continue"),
        ("already a subscriber? sign in", "marker: already a subscriber sign-in"),
        ("unlock this article", "marker: unlock this article"),
        ("unlock full access", "marker: unlock full access"),
        ("to continue reading this article", "marker: continue-reading wall copy"),
        ("paywall", "marker: paywall naming"),
        ("isPaywalled\":true", "marker: isPaywalled state"),
        ("\"paywalled\":true", "marker: paywalled state"),
        ("gateway-partial", "marker: news-corp gateway partial"),
        ("cmp-paywall", "marker: consent-manager paywall"),
    ]

    /// Below this many extractable characters, an article page is presumed
    /// truncated (server-side cut) — but ONLY when combined with a real
    /// signal, never on its own: short pages exist.
    static let truncatedTextLength = 600

    /// Inspects fetched HTML. `extractedTextLength` is how much article
    /// text the readability pass managed to pull out of that same HTML;
    /// a long page whose article container holds a stub is the classic
    /// hard-paywall shape.
    public static func inspect(html: String, extractedTextLength: Int? = nil) -> Inspection {
        var reasons: [String] = []
        // One lowercased pass for every phrase test.
        let lowered = html.lowercased()

        for (phrase, reason) in markerPhrases where lowered.contains(phrase.lowercased()) {
            reasons.append(reason)
        }

        // Structured signal: JSON-LD claiming the article is NOT free.
        if lowered.contains("isaccessibleforfree") {
            // "false" can ride next to it in any spacing/quote style; a
            // nearby `false` within a few dozen chars beats regex heroics.
            if let range = lowered.range(of: "isaccessibleforfree") {
                let window = lowered[range.lowerBound...].prefix(80)
                if window.contains("false") {
                    reasons.append("jsonld: isAccessibleForFree=false")
                }
            }
        }

        // Truncation: an og:description that promises real content while
        // the page yielded almost none. The meta description is the
        // publisher's own summary of the article that should be there.
        if let extracted = extractedTextLength,
           extracted < truncatedTextLength,
           let descriptionLength = ogDescriptionLength(html: lowered),
           descriptionLength > 140 {
            reasons.append("truncated: \(extracted) chars extracted vs og:description \(descriptionLength)")
        }

        return reasons.isEmpty ? .clean : Inspection(paywalled: true, reasons: reasons)
    }

    /// Length of the og:description / meta-description content, whichever
    /// is present. Takes already-lowercased HTML (content length is the
    /// same either way).
    static func ogDescriptionLength(html: String) -> Int? {
        for metaName in ["og:description", "\"description\""] {
            guard let tagRange = html.range(of: metaName) else { continue }
            // content="…" or content='…' after the name attribute — plain
            // prefix scan, attributes come in either order and the tag is
            // short.
            let window = html[tagRange.lowerBound...].prefix(400)
            guard let contentStart = window.range(of: "content=") else { continue }
            let remainder = window[contentStart.upperBound...]
            let quote = remainder.first { $0 == "\"" || $0 == "'" } ?? " "
            guard let valueStart = remainder.range(of: String(quote), range: remainder.startIndex..<remainder.endIndex) else { continue }
            let afterQuote = remainder[valueStart.upperBound...]
            let value = afterQuote.prefix(while: { $0 != quote })
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.count }
        }
        return nil
    }
}
