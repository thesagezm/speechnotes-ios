import XCTest
@testable import SpeechLogic

/// Reader-mode extraction for fetched web pages: chrome removal, the
/// marked-content region preference, URL detection for the share channels,
/// and the graceful degradation chain (region → cleaned page → raw HTML).
final class WebArticleTests: XCTestCase {

    // MARK: - URL detection

    func testPlainHTTPURLIsDetected() {
        XCTAssertEqual(WebArticle.url(in: "https://example.com/story"), URL(string: "https://example.com/story"))
        XCTAssertEqual(WebArticle.url(in: "http://example.com"), URL(string: "http://example.com"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            WebArticle.url(in: "  https://example.com/a?b=1\n"),
            URL(string: "https://example.com/a?b=1"))
    }

    func testSchemeLessDomainGetsHTTPSAndAPlausibleTLD() {
        XCTAssertEqual(
            WebArticle.url(in: "example.com/story.html"),
            URL(string: "https://example.com/story.html"))
        XCTAssertEqual(
            WebArticle.url(in: "www.nytimes.com/2026/11/07/us/story"),
            URL(string: "https://www.nytimes.com/2026/11/07/us/story"))
    }

    func testProseAndVersionStringsStayText() {
        // Anything with spaces or newlines is prose the user meant to keep.
        XCTAssertNil(WebArticle.url(in: "read https://example.com later"))
        XCTAssertNil(WebArticle.url(in: "https://example.com\nand more"))
        // Version strings fail the TLD test (last label is digits/one char).
        XCTAssertNil(WebArticle.url(in: "v1.7.4"))
        XCTAssertNil(WebArticle.url(in: "1.2"))
        XCTAssertNil(WebArticle.url(in: "192.168.1.1"))
        XCTAssertNil(WebArticle.url(in: ""))
    }

    // MARK: - Chrome removal

    func testNavigationChromeIsRemoved() {
        let html = """
        <html><body>
        <nav><a href="/">Home</a><a href="/sections">Sections</a>Sign In</nav>
        <article><h1>The Story</h1><p>Real prose lives here.</p></article>
        <footer><a href="/about">About</a><a href="/careers">Careers</a></footer>
        </body></html>
        """
        let article = WebArticle.extract(html: Data(html.utf8))
        XCTAssertNotNil(article)
        XCTAssertTrue(article!.text.contains("Real prose lives here."))
        XCTAssertFalse(article!.text.contains("Sign In"))
        XCTAssertFalse(article!.text.contains("Careers"))
    }

    func testScriptStyleAndFormBodiesAreRemoved() {
        let html = """
        <html><head><script>var tracked = "not prose";</script>
        <style>.banner { color: red; }</style></head><body>
        <form><label>Email</label><input type="email"><button>Subscribe</button></form>
        <p>The actual article text.</p>
        </body></html>
        """
        let article = WebArticle.extract(html: Data(html.utf8))
        XCTAssertNotNil(article)
        XCTAssertTrue(article!.text.contains("The actual article text."))
        XCTAssertFalse(article!.text.contains("Subscribe"))
        XCTAssertFalse(article!.text.contains("tracked"))
        XCTAssertFalse(article!.text.contains("banner"))
    }

    // MARK: - Region preference

    func testArticleRegionBeatsSurroundingLinkFarms() {
        // The nav-stripper cannot know a bare link list in the page BODY is
        // a "Trending" rail — the region preference is what drops it.
        let html = """
        <html><body>
        <h2>Trending</h2><p>Celebrity did a thing. Sports team won. Stock moved.</p>
        <p>Another headline. Weather forecast teaser. More news you didn't ask for here.</p>
        <article><h1>The Real Article</h1>
        <p>This is the body the reader came for, and it is long enough to dominate the page's
        visible text weight by a wide margin, paragraph after paragraph of actual journalism
        filling the column with sentences that should survive into the note.</p>
        <p>Second paragraph of the body, equally substantial, keeping the article's share of
        the page's text well above the forty percent floor the region preference requires.</p>
        </article>
        </body></html>
        """
        let article = WebArticle.extract(html: Data(html.utf8))
        XCTAssertNotNil(article)
        XCTAssertTrue(article!.text.contains("The Real Article"))
        XCTAssertTrue(article!.text.contains("Second paragraph of the body"))
        XCTAssertFalse(article!.text.contains("Celebrity did a thing"))
    }

    func testTinyMarkedRegionDoesNotReplaceTheFullPage() {
        // A teaser listing marks each teaser `<article>`; none reaches the
        // weight floor, so the whole page survives.
        let html = """
        <html><body>
        <article><p>Teaser one.</p></article>
        <article><p>Teaser two.</p></article>
        <p>Directory body text that is long enough to be the bulk of the page's visible weight,
        with real content outside every marked region, which is exactly the shape of an index
        page that lists many small articles without marking the page itself.</p>
        </body></html>
        """
        let article = WebArticle.extract(html: Data(html.utf8))
        XCTAssertNotNil(article)
        XCTAssertTrue(article!.text.contains("Teaser one."))
        XCTAssertTrue(article!.text.contains("Directory body text"))
    }

    func testRoleMainDivIsHonored() {
        // Enough prose inside the region (and little outside) that the
        // region pick actually fires — with everything below the 400-char
        // threshold the test would pass through the whole-page fallback.
        let body = """
        <html><body>
        <div role="main"><h1>Shell Content</h1>
        <p>The main region's prose, written long enough to dominate the page's visible text
        weight by a comfortable margin, sentence after sentence of ordinary column filler
        that a reader-mode pass should keep whole.</p>
        <p>And a second paragraph inside the same region for the same reason, keeping the
        region's share of the page far above the forty percent floor.</p>
        <p>A third paragraph supplies the remaining visible weight, keeping the marked main
        region comfortably above the four-hundred-character minimum used by the reader-mode
        selector so this test exercises narrowing rather than the whole-page fallback.</p></div>
        <p>Outside filler.</p>
        </body></html>
        """
        let article = WebArticle.extract(html: Data(body.utf8))
        XCTAssertNotNil(article)
        XCTAssertTrue(article!.text.contains("The main region's prose"))
        XCTAssertFalse(article!.text.contains("Outside filler"))
    }

    // MARK: - Degradation chain

    func testUnclosedJunkBlockDoesNotSwallowThePage() {
        // A `<form>` never closed: past the artifact bound the cleaner
        // force-closes it instead of dropping the whole body. The filler
        // must exceed `maxJunkBlockSize` (250k source chars) for the
        // force-close to be the mechanism under test.
        let filler = String(repeating: "<p>Filler sentence the artifact-bound test needs. </p>", count: 6000)
        let html = "<html><body><form><input type=\"text\"><label>Email us</label>" + filler
        let article = WebArticle.extract(html: Data(html.utf8))
        XCTAssertNotNil(article)
        XCTAssertTrue(article!.text.contains("Filler sentence"))
        XCTAssertFalse(article!.text.contains("Email us"))
    }

    func testPageWithNoTextReturnsNil() {
        XCTAssertNil(WebArticle.extract(html: Data("<html><head></head><body></body></html>".utf8)))
    }

    // MARK: - Metadata + text fidelity

    func testTitleComesFromHeadEvenWhenRegionStartsBelowIt() {
        // The region carries the whole article; `<head>` is outside it — the
        // title must still come from there.
        let html = """
        <html><head><title>The Headline</title>
        <meta property="og:title" content="The OG Headline"></head><body>
        <article><p>A body of enough words to pass the region floor on its own, padded with
        several more sentences of ordinary prose so the weight arithmetic works out in the
        region's favor. This paragraph repeats its point at greater length because the
        threshold is a text-weight comparison against the whole cleaned page, and the head
        itself contributes no visible words at all.</p></article>
        </body></html>
        """
        let article = WebArticle.extract(html: Data(html.utf8))
        XCTAssertEqual(article?.title, "The Headline")
        XCTAssertTrue(article!.text.contains("weight arithmetic"))
    }

    func testEntitiesDecodeInExtractedProse() {
        let html = "<html><body><p>Caf&eacute; & na&iuml;ve &mdash; the caf&eacute; test.</p></body></html>"
        let article = WebArticle.extract(html: Data(html.utf8))
        XCTAssertTrue(article!.text.contains("Café & naïve"))
        XCTAssertTrue(article!.text.contains("—") || article!.text.contains("&mdash;"))
    }
}
