import XCTest
@testable import SpeechLogic

final class ZipReaderTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "epub", subdirectory: "Fixtures"),
            "fixture \(name).epub missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    func testEntriesListAllRecordsInOrder() throws {
        let entries = try ZipReader.entries(in: fixture("sample"))
        XCTAssertEqual(entries.first?.name, "mimetype")
        XCTAssertEqual(entries.map(\.name), [
            "mimetype",
            "META-INF/container.xml",
            "OEBPS/content.opf",
            "OEBPS/chap1.xhtml",
            "OEBPS/chap2.xhtml",
            "OEBPS/toc.ncx",
            "OEBPS/cover.jpg",
        ])
        XCTAssertFalse(entries.first!.isDirectory)
    }

    func testReadsStoredEntry() throws {
        let data = try ZipReader.readEntry("mimetype", in: fixture("sample"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "application/epub+zip")
    }

    func testReadsDeflatedTextEntry() throws {
        let data = try ZipReader.readEntry("META-INF/container.xml", in: fixture("sample"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("OEBPS/content.opf"), "container.xml should name the OPF, got: \(text)")
    }

    func testReadsDeflatedBinaryEntryToExactSize() throws {
        let data = try ZipReader.readEntry("OEBPS/cover.jpg", in: fixture("sample"))
        XCTAssertEqual(data.count, 332)
        // JPEG SOI marker survives the round trip.
        XCTAssertEqual([UInt8](data.prefix(2)), [0xFF, 0xD8])
    }

    func testMissingEntryThrows() throws {
        XCTAssertThrowsError(try ZipReader.readEntry("OEBPS/nope.xhtml", in: fixture("sample"))) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .entryNotFound(name: "OEBPS/nope.xhtml"))
        }
    }

    func testGarbageDataThrowsNotAZip() {
        XCTAssertThrowsError(try ZipReader.entries(in: Data("definitely not a zip".utf8))) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .notAZipFile)
        }
    }

    func testEmptyDataThrowsNotAZip() {
        XCTAssertThrowsError(try ZipReader.entries(in: Data())) { error in
            XCTAssertEqual(error as? ZipReader.ZipError, .notAZipFile)
        }
    }
}

final class EpubInfoTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "epub", subdirectory: "Fixtures"),
            "fixture \(name).epub missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    // MARK: EPUB 2 conventions (meta name="cover", NCX TOC)

    func testParsesEPUB2Fixture() throws {
        let info = try EpubParser.parse(archive: fixture("sample"))
        XCTAssertEqual(info.title, "The Test Book")
        XCTAssertEqual(info.creator, "Fixture Author")
        XCTAssertEqual(info.language, "en")
        XCTAssertEqual(info.spine, ["OEBPS/chap1.xhtml", "OEBPS/chap2.xhtml"])
        // Cover via <meta name="cover" content="cover-image"> → manifest href.
        XCTAssertEqual(info.coverPath, "OEBPS/cover.jpg")
        // TOC via toc.ncx (the spine's toc= target).
        XCTAssertEqual(info.toc, [
            EpubTocEntry(label: "Chapter One", href: "OEBPS/chap1.xhtml"),
            EpubTocEntry(label: "Chapter Two", href: "OEBPS/chap2.xhtml"),
        ])
    }

    // MARK: EPUB 3 conventions (properties="cover-image"/"nav", subdirectories)

    func testParsesEPUB3Fixture() throws {
        let info = try EpubParser.parse(archive: fixture("sample-epub3"))
        XCTAssertEqual(info.title, "A Modern Fixture")
        XCTAssertEqual(info.creator, "EPUB Three")
        XCTAssertEqual(info.language, "en-GB")
        XCTAssertEqual(info.spine, ["OEBPS/text/chap1.xhtml", "OEBPS/text/chap2.xhtml"])
        XCTAssertEqual(info.coverPath, "OEBPS/images/cover.jpg")
        // nav.xhtml picked over any other <nav>; whitespace runs in multi-line
        // labels collapse; hrefs resolve relative to text/.
        XCTAssertEqual(info.toc, [
            EpubTocEntry(label: "The Beginning", href: "OEBPS/text/chap1.xhtml"),
            EpubTocEntry(label: "The Middle Years", href: "OEBPS/text/chap2.xhtml"),
        ])
        // Cover bytes round-trip through the resolved subdirectory path.
        let cover = try ZipReader.readEntry(info.coverPath!, in: fixture("sample-epub3"))
        XCTAssertGreaterThan(cover.count, 50)
    }

    // MARK: Path resolution

    func testDirectoryOfPath() {
        XCTAssertEqual(EpubParser.directory(of: "OEBPS/content.opf"), "OEBPS")
        XCTAssertEqual(EpubParser.directory(of: "mimetype"), "")
        XCTAssertEqual(EpubParser.directory(of: "a/b/c.opf"), "a/b")
    }

    func testResolveJoinsRelativeToBaseDir() {
        XCTAssertEqual(EpubParser.resolve("chap1.xhtml", relativeTo: "OEBPS"), "OEBPS/chap1.xhtml")
        XCTAssertEqual(EpubParser.resolve("chap1.xhtml", relativeTo: ""), "chap1.xhtml")
    }

    func testResolveCollapsesDotDot() {
        XCTAssertEqual(EpubParser.resolve("../styles/main.css", relativeTo: "OEBPS/text"), "OEBPS/styles/main.css")
    }

    func testResolveStripsFragment() {
        XCTAssertEqual(EpubParser.resolve("chap1.xhtml#section-2", relativeTo: "OEBPS"), "OEBPS/chap1.xhtml")
    }

    // MARK: Broken containers

    func testGarbageArchiveThrowsMissingContainer() {
        XCTAssertThrowsError(try EpubParser.parse(archive: Data("junk".utf8))) { error in
            XCTAssertEqual(error as? EpubParser.EpubError, .missingContainer)
        }
    }
}

// MARK: - CRC verification (v1.5 sage round)

extension ZipReaderTests {

    /// Flipping a payload byte must be CAUGHT — size-only validation used to
    /// accept plausible-length garbage that then got cached as chapter text.
    func testCorruptStoredPayloadFailsCRC() throws {
        let data = fixture("sample")
        let entries = try ZipReader.entries(in: data)
        let mimetype = try XCTUnwrap(entries.first { $0.name == "mimetype" })

        // Payload offset: local header (30) + local name + local extra.
        let headerAt = mimetype.localHeaderOffset
        let nameLength = Int(data[headerAt + 26]) | (Int(data[headerAt + 27]) << 8)
        let extraLength = Int(data[headerAt + 28]) | (Int(data[headerAt + 29]) << 8)
        let payloadAt = headerAt + 30 + nameLength + extraLength

        var corrupted = data
        corrupted[payloadAt] ^= 0xFF

        XCTAssertThrowsError(try ZipReader.readEntry("mimetype", in: corrupted)) { error in
            guard case ZipReader.ZipError.corrupt = error else {
                return XCTFail("expected .corrupt, got \\(error)")
            }
        }
    }

    func testIntactEntriesStillPassCRC() throws {
        let data = fixture("sample")
        let entries = try ZipReader.entries(in: data)
        XCTAssertTrue(entries.contains { $0.crc != 0 }, "fixture entries should carry real CRCs")
        // Every stored+deflated entry reads back cleanly (all CRCs match).
        for entry in entries where !entry.isDirectory {
            try ZipReader.read(entry, in: data)
        }
    }
}
