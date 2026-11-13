import Foundation
import XCTest
@testable import SpeechLogic

/// The native reader's page set: what a parsed document becomes on disk
/// under `doc/`. The pages are the same serializers the EPUB converter uses
/// — only the image hrefs differ (`img/<n>.<ext>`, relative to the chapter
/// page, so the reader's scheme handler answers them). The cover rides both
/// as an image (for the reader's cover page) and as the first spine page.
final class DocumentPagesTests: XCTestCase {
    func testChapterPagesImagesAndCoverLand() {
        let chapters = [
            DocumentChapter(title: "One", blocks: [
                .paragraph("hello"),
                .image(0),
                .table([[DocumentTableCell(text: "a", columnSpan: 1, isHeader: false)]]),
            ]),
            DocumentChapter(title: nil, blocks: [
                .html("<h1>Hi</h1><p>body</p>"),
                .image(1),
            ]),
        ]
        let images = [
            DocumentImage(data: Data(repeating: 7, count: 400), mime: "image/png"),
            DocumentImage(data: Data([4]), mime: "image/jpeg"),
        ]
        let cover = DocumentImage(data: Data([9, 9]), mime: "image/jpeg")

        let files = DocumentPages.files(chapters: chapters, images: images, cover: cover)
        XCTAssertEqual(files.map(\.path), [
            "chapter-0.html", "chapter-1.html",
            "img/0.png", "img/1.jpg",
            "img/cover.jpg", "cover.html",
        ])

        // Chapter 0's image block references the pool entry by its
        // page-relative href — "img/0.png" resolves against the chapter page
        // onto the served "img/0.png".
        let ch0 = String(decoding: files[0].data, as: UTF8.self)
        XCTAssertTrue(ch0.contains(#"<img class="doc-image-inline" src="img/0.png""#), ch0)
        XCTAssertTrue(ch0.contains("<p>hello</p>"), ch0)
        XCTAssertTrue(ch0.contains("doc-table"), ch0)

        // Native markup passes through with only the image token rewritten
        // (an explicit src is left alone; a token would swap to the href).
        let ch1 = String(decoding: files[1].data, as: UTF8.self)
        XCTAssertTrue(ch1.contains("<h1>Hi</h1>"), ch1)
        XCTAssertTrue(ch1.contains(#"src="img/1.jpg""#), ch1)

        // The size sniffer reads real image headers only — undecodable
        // bytes class inline (natural size, capped), the same rule the
        // EPUB converter applies to its tiny-GIF fixture.
        XCTAssertTrue(ch0.contains(#"class="doc-image-inline" src="img/0.png""#), ch0)
        XCTAssertTrue(ch1.contains(#"class="doc-image-inline" src="img/1.jpg""#), ch1)

        // The cover page opens the spine and references the cover image.
        let coverPage = String(decoding: files.last!.data, as: UTF8.self)
        XCTAssertTrue(coverPage.contains(#"src="img/cover.jpg""#), coverPage)
        let coverImage = files.first(where: { $0.path == "img/cover.jpg" })
        XCTAssertEqual(coverImage?.data, cover.data)
    }

    func testNoCoverMeansNoCoverPage() {
        let files = DocumentPages.files(
            chapters: [DocumentChapter(title: nil, blocks: [.paragraph("x")])],
            images: [],
            cover: nil
        )
        XCTAssertEqual(files.map(\.path), ["chapter-0.html"])
        // A titleless chapter still gets the plain index label for the
        // running head, which is not rendered as content.
        let html = String(decoding: files[0].data, as: UTF8.self)
        XCTAssertTrue(html.contains("<title>Chapter 1</title>"), html)
    }

    func testImageHrefsAreUrlSafe() {
        // The names land in a URL path served by the scheme handler — every
        // generated name must be letters, digits, - _ and . only.
        let files = DocumentPages.files(
            chapters: (0..<3).map { DocumentChapter(title: "C\($0)", blocks: [.image(0)]) },
            images: [DocumentImage(data: Data([1]), mime: "image/png")],
            cover: DocumentImage(data: Data([2]), mime: "image/gif")
        )
        for file in files {
            for component in file.path.split(separator: "/") {
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                XCTAssertTrue(component.unicodeScalars.allSatisfy { allowed.contains($0) },
                              "\(file.path) must be URL-safe")
            }
        }
    }
}
