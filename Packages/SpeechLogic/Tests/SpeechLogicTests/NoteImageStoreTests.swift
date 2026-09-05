import XCTest
@testable import SpeechLogic

final class NoteImageStoreTests: XCTestCase {

    private var noteId: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }

    override func tearDownWithError() throws {
        let dir = NoteImageStore.directory(for: noteId)
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    func testStoreDeduplicatesByContentHash() {
        let bytes = Data((0..<64).map { UInt8($0) })
        let a = NoteImageStore.store(data: bytes, ext: "png", noteId: noteId)
        let b = NoteImageStore.store(data: bytes, ext: "png", noteId: noteId)
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a)
        XCTAssertTrue(a!.hasPrefix("speechnotes://note-image/"))
    }

    func testResolveLocalURLRoundTrips() {
        let bytes = Data(repeating: 7, count: 32)
        guard let target = NoteImageStore.store(data: bytes, ext: "jpg", noteId: noteId) else {
            XCTFail("store failed"); return
        }
        let url = NoteImageStore.resolveLocalURL(target, noteId: noteId)
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
    }

    func testParseLocalTarget() {
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
    }

    func testParseLocalTarget() {
        let target = "speechnotes://note-image/abcd.png"
        let parsed = NoteImageStore.parseLocalTarget(target)
        XCTAssertEqual(parsed?.hash, "abcd")
        XCTAssertEqual(parsed?.ext, "png")
    }

    func testRejectsNonImageExtensions() {
        XCTAssertNil(NoteImageStore.sanitiseExtension(nil))
        XCTAssertEqual(NoteImageStore.sanitiseExtension(".PNG"), "png")
        XCTAssertEqual(NoteImageStore.sanitiseExtension("jpeg"), "jpg")
        XCTAssertEqual(NoteImageStore.sanitiseExtension("exe"), "bin")
        XCTAssertEqual(NoteImageStore.sanitiseExtension(".bin"), "bin")
        XCTAssertNil(NoteImageStore.sanitiseExtension(""))
    }

    func testResolveReturnsNilForRemoteURL() {
        XCTAssertNil(NoteImageStore.resolveLocalURL("https://example.com/x.png", noteId: noteId))
    }
}
