import XCTest
@testable import SpeechLogic

/// ReaderModeExtraction: the reader-mode plan the extraction script
/// follows. The lists are the contract between the package and the
/// page-side script, so they are pinned here.
final class ReaderModeExtractionTests: XCTestCase {

    // MARK: - The article fast path

    func testArticleTagOpensTheFastPath() {
        let html = "<html><body><article><p>The story.</p></article></body></html>"
        XCTAssertTrue(ReaderModeExtraction.hasArticleRoot(inHTML: html))
        XCTAssertTrue(ReaderModeExtraction.plan(forHTML: html).useArticleFastPath)
    }

    func testMainTagOpensTheFastPath() {
        let html = "<html><body><main><p>The story.</p></main></body></html>"
        XCTAssertTrue(ReaderModeExtraction.hasArticleRoot(inHTML: html))
    }

    func testMainRoleOpensTheFastPath() {
        let html = "<html><body><div role=\"main\"><p>The story.</p></div></body></html>"
        XCTAssertTrue(ReaderModeExtraction.hasArticleRoot(inHTML: html))
    }

    func testArticleTagIsFoundWhateverTheCase() {
        XCTAssertTrue(ReaderModeExtraction.hasArticleRoot(inHTML: "<ARTICLE><p>x</p></ARTICLE>"))
    }

    func testPageWithoutAnArticleRootKeepsTheScoredPath() {
        let html = "<html><body><div class=\"post\"><p>The story.</p></div></body></html>"
        XCTAssertFalse(ReaderModeExtraction.hasArticleRoot(inHTML: html))
        XCTAssertFalse(ReaderModeExtraction.plan(forHTML: html).useArticleFastPath)
    }

    // MARK: - The chrome pre-strip

    func testNavigationChromeIsStripped() {
        for selector in ["nav", "footer", "#sidebar", ".menu", "#p-navigation"] {
            XCTAssertTrue(
                ReaderModeExtraction.chromeSelectors.contains(selector),
                "\(selector) must be stripped before the article is scored"
            )
        }
    }

    func testFormControlsAreStripped() {
        for selector in ["input", "textarea", "form", "button", "select"] {
            XCTAssertTrue(
                ReaderModeExtraction.chromeSelectors.contains(selector),
                "\(selector) must be stripped — a comment box is not prose"
            )
        }
    }

    func testImagesAreNotStripped() {
        // This importer keeps pictures: the markdown walker emits
        // ![alt](src), so dropping the images here would lose them.
        XCTAssertFalse(ReaderModeExtraction.chromeSelectors.contains("img"))
    }

    func testAsidesAreNotStripped() {
        // The walker already skips asides on its own; stripping them here
        // as well would take a side note out of the article.
        XCTAssertFalse(ReaderModeExtraction.chromeSelectors.contains("aside"))
    }

    // MARK: - The article-root order

    func testArticleComesFirstInTheRootOrder() {
        XCTAssertEqual(ReaderModeExtraction.articleRootSelectors.first, "article")
        XCTAssertEqual(ReaderModeExtraction.articleRootSelectors.dropFirst().first, "main")
    }

    func testTheThresholdIsTheOneTheScriptUses() {
        XCTAssertEqual(ReaderModeExtraction.plan(forHTML: "<p>x</p>").minArticleChars, 400)
        XCTAssertEqual(ReaderModeExtraction.minArticleChars, 400)
    }

    // MARK: - The JSON the script reads

    func testSelectorsJSONCarriesTheLists() throws {
        let json = ReaderModeExtraction.selectorsJSON
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strip = try XCTUnwrap(object["stripSelectors"] as? [String])
        let roots = try XCTUnwrap(object["articleRootSelectors"] as? [String])
        XCTAssertEqual(strip, ReaderModeExtraction.chromeSelectors)
        XCTAssertEqual(roots, ReaderModeExtraction.articleRootSelectors)
        XCTAssertEqual(object["minArticleChars"] as? Int, 400)
    }
}
