import XCTest
@testable import SpeechLogic

/// PaywallHeuristics: the gate that decides whether a web import reroutes
/// through the Bypass Paywalls Clean pass. High precision matters more than
/// recall — a missed soft wall just imports what's there, but a false
/// positive sends every clean article through the slow bypass webview.
final class PaywallHeuristicsTests: XCTestCase {

    func testCleanArticleIsNotPaywalled() {
        let html = """
        <html><head><title>News</title>
        <meta property="og:description" content="The council voted 7-2 on Tuesday to expand the transit line after a long debate about funding.">
        </head><body><article><p>The council voted 7-2 on Tuesday to expand the transit line after a long debate about funding.</p>
        <p>Construction begins in March, officials said, and the first phase should open within two years of groundbreaking.</p></article></body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 2_400)
        XCTAssertEqual(inspection, .clean)
        XCTAssertFalse(inspection.paywalled)
    }

    func testNewsletterSubscribeCopyDoesNotCount() {
        // "subscribe to our newsletter" is on every free page — the marker
        // phrases must not match it.
        let html = """
        <html><body><article><p>The full three-thousand-word feature story sits here in the page
        and is entirely readable without an account.</p></article>
        <footer>Subscribe to our newsletter for more.</footer></body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 3_100)
        XCTAssertEqual(inspection, .clean)
    }

    func testSoftWallOverlayCopyIsDetected() {
        let html = """
        <html><body><article><p>One introductory paragraph before the wall.</p></article>
        <div class="paywall-overlay"><h2>Subscribe to continue reading</h2>
        <p>Get unlimited access. Already a subscriber? Sign in.</p></div></body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 180)
        XCTAssertTrue(inspection.paywalled)
        XCTAssertTrue(inspection.reasons.contains { $0.contains("subscribe to continue") })
        XCTAssertTrue(inspection.reasons.contains { $0.contains("already a subscriber") })
    }

    func testJsonldNotFreeIsDetected() {
        let html = """
        <html><head><script type="application/ld+json">
        {"@type":"NewsArticle","isAccessibleForFree":false,"headline":"Markets fall"}
        </script></head><body><article><p>Markets fell sharply.</p></article></body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 240)
        XCTAssertTrue(inspection.paywalled)
        XCTAssertTrue(inspection.reasons.contains("jsonld: isAccessibleForFree=false"))
    }

    func testJsonldFreeIsNotFlagged() {
        let html = """
        <html><head><script type="application/ld+json">
        {"@type":"NewsArticle","isAccessibleForFree":true,"headline":"Markets rise"}
        </script></head><body><article><p>Markets rose sharply on the news, closing at their
        highest level in months as investors weighed the outlook.</p></article></body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 1_200)
        XCTAssertEqual(inspection, .clean)
    }

    func testHardWallTruncationIsDetected() {
        // Server-side cut: og:description promises a real story, the page
        // itself yields a stub.
        let html = """
        <html><head>
        <meta property="og:description" content="Inside the two-year investigation that uncovered the fraud at the heart of the company, from the first tipster to this week's indictment, with never-reported details about the money trail.">
        </head><body><article><p>A federal grand jury indicted three executives on Thursday.</p>
        <div class="gateway-partial"></div></article></body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 90)
        XCTAssertTrue(inspection.paywalled)
        XCTAssertTrue(inspection.reasons.contains { $0.contains("gateway-partial") })
        XCTAssertTrue(inspection.reasons.contains { $0.contains("truncated") })
    }

    func testShortCleanPageIsNotTruncationFlagged() {
        // A genuinely short page (no long og:description promise) must not
        // trip the truncation signal.
        let html = """
        <html><head><meta property="og:description" content="Brief."></head>
        <body><article><p>Short but complete note about a thing.</p></article></body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 120)
        XCTAssertEqual(inspection, .clean)
    }

    func testNewsCorpGatewayContainerIsDetected() {
        let html = """
        <html><body><article><p class="gateway-partial">The first paragraph...</p></article>
        </body></html>
        """
        let inspection = PaywallHeuristics.inspect(html: html, extractedTextLength: 400)
        XCTAssertTrue(inspection.paywalled)
    }

    func testReasonsAreLoggedStyleStrings() {
        let inspection = PaywallHeuristics.inspect(
            html: "<html><body>Subscription Required</body></html>",
            extractedTextLength: 100
        )
        XCTAssertTrue(inspection.paywalled)
        XCTAssertEqual(inspection.reasons, ["marker: subscription required"])
    }
}
