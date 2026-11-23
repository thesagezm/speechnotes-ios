//
//  ReaderModeExtraction.swift
//  SpeechLogic
//
//  The reader-mode PLAN: what the extraction script should strip before it
//  decides what the article is, and where it should look for the article
//  itself.
//
//  Why this file exists: the importer already runs Mozilla Readability on
//  every fetched page, and Readability is good — but it is a SCORING
//  algorithm, and a scoring algorithm can be persuaded by a page's
//  furniture. A sticky header, a "related articles" rail or a footer full
//  of links can out-score the article body, and the import then carries
//  the furniture instead of the story.
//
//  Two ideas from the open-source reader-mode extensions this round
//  studied (kushagrasinghx/reader-mode-extension @ d6b677f — note its
//  own "readability.js" is a 15-line STUB, and its real algorithm lives
//  in contentScript.js) are worth keeping:
//
//  1. a SELECTOR-BASED PRE-STRIP of nav / footer / sidebar chrome BEFORE
//     the scoring runs — the chrome is removed, so it cannot win the
//     scoring;
//  2. an ARTICLE-ELEMENT FAST PATH — a page that carries a real
//     <article> (or <main>) already says where its article is, so the
//     scoring can be skipped entirely.
//
//  Two ideas from it are NOT copied: dropping `img` (this importer keeps
//  pictures — the markdown walker emits `![alt](src)`) and dropping
//  `aside` (the walker already skips asides on its own).
//
//  The lists live HERE, in the package, so the page-side script and this
//  module cannot drift: the script reads them from the JSON this file
//  produces. Pure data + pure decisions, so the logic-tests job in CI
//  exercises them on every push.
//

import Foundation

/// The reader-mode plan: what to strip, where to look, and whether the
/// fast path may be taken.
public enum ReaderModeExtraction {

    /// The chrome removed BEFORE the article is chosen.
    ///
    /// Navigation, footers, sidebars and the menu — the furniture every
    /// publisher's template carries — plus the form controls (a comment
    /// box inside the article would otherwise be scored as prose).
    ///
    /// NOT in the list: `img` (pictures are content here) and `aside`
    /// (the markdown walker already skips asides).
    public static let chromeSelectors: [String] = [
        "nav",
        "footer",
        "#footer",
        ".footer",
        "#sidebar",
        ".sidebar",
        ".navigation",
        ".nav",
        ".menu",
        ".mw-sidebar",
        ".mw-portlet",
        ".portal",
        "#mw-navigation",
        "#siteSub",
        "#p-navigation",
        "input",
        "textarea",
        "form",
        "button",
        "select",
    ]

    /// Where an article root is looked for, in preference order.
    ///
    /// The first candidate that carries enough text wins. A page with a
    /// real <article> says where its article is; <main> is the modern
    /// equivalent; the class names are the ones publishers use for the
    /// story body when they use neither.
    public static let articleRootSelectors: [String] = [
        "article",
        "main",
        "[role=\"main\"]",
        ".post-content",
        ".entry-content",
        ".article-content",
        ".article-body",
        ".story-body",
    ]

    /// How much text an article root must carry before the fast path
    /// trusts it. A stub <article> — a "related posts" box, an empty
    /// shell a single-page app fills in later — must not win over the
    /// scoring path.
    public static let minArticleChars = 400

    /// The plan for one page.
    public struct Plan: Codable, Equatable, Sendable {
        /// The selectors to remove before the article is chosen.
        public let stripSelectors: [String]
        /// The article-root candidates, in preference order.
        public let articleRootSelectors: [String]
        /// Whether the fast path may be taken at all (the page carries an
        /// article root).
        public let useArticleFastPath: Bool
        /// The minimum number of characters the article root must carry.
        public let minArticleChars: Int

        public init(
            stripSelectors: [String],
            articleRootSelectors: [String],
            useArticleFastPath: Bool,
            minArticleChars: Int
        ) {
            self.stripSelectors = stripSelectors
            self.articleRootSelectors = articleRootSelectors
            self.useArticleFastPath = useArticleFastPath
            self.minArticleChars = minArticleChars
        }
    }

    /// The plan for a page whose HTML is already known.
    ///
    /// The page-side script recomputes the same decision against the LIVE
    /// DOM (the bypass pass's DOM is not the fetched one — BPC may have
    /// reloaded the page or restored an archive copy), so this is the
    /// import LOG's answer and the shape the tests pin.
    public static func plan(forHTML html: String) -> Plan {
        Plan(
            stripSelectors: chromeSelectors,
            articleRootSelectors: articleRootSelectors,
            useArticleFastPath: hasArticleRoot(inHTML: html),
            minArticleChars: minArticleChars
        )
    }

    /// Whether the HTML carries an article root at all.
    ///
    /// A cheap scan of the markup — the tag or the role attribute, case
    /// insensitively. It cannot know how much text the root carries (that
    /// is the script's job), only that the page admits where its article
    /// is.
    public static func hasArticleRoot(inHTML html: String) -> Bool {
        let lowered = html.lowercased()
        if lowered.contains("<article") { return true }
        if lowered.contains("<main") { return true }
        if lowered.contains("role=\"main\"") || lowered.contains("role='main'") { return true }
        return false
    }

    /// The selector lists as JSON — what the page-side script reads, so
    /// the two cannot drift.
    ///
    /// The JSON carries the LISTS and the threshold only: whether a
    /// particular page takes the fast path is decided in the script,
    /// against the live DOM.
    public static var selectorsJSON: String {
        let payload: [String: Any] = [
            "stripSelectors": chromeSelectors,
            "articleRootSelectors": articleRootSelectors,
            "minArticleChars": minArticleChars,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"stripSelectors\":[],\"articleRootSelectors\":[],\"minArticleChars\":0}"
        }
        return json
    }
}
