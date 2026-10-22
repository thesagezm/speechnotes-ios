import XCTest
@testable import SpeechLogic

/// The vault layer: key material, sealing, and the notes-file shape.
///
/// These tests are deliberately cheap where they can be (the file-shape
/// logic does not need a real key) and pay the 220 000-iteration KDF only
/// where the passphrase path is what is under test.
final class JoplinVaultTests: XCTestCase {

    /// One key material, shared by the tests that need one. Deriving it
    /// costs a full PBKDF2 run, so it is made once.
    private static var material: JoplinVaultKeyMaterial.Material?

    private func material() throws -> JoplinVaultKeyMaterial.Material {
        if let cached = Self.material { return cached }
        let fresh = try JoplinVaultKeyMaterial.create(passphrase: "a test passphrase")
        Self.material = fresh
        return fresh
    }

    // MARK: - Key material

    /// The material must have Joplin's shapes: a 512-hex master key, a
    /// 32-hex id, and a wrapped copy that is NOT the master.
    func testMaterialHasJoplinShapes() throws {
        let fresh = try JoplinVaultKeyMaterial.create(passphrase: "a test passphrase")
        XCTAssertEqual(fresh.master.count, 512)
        XCTAssertEqual(fresh.id.count, 32)
        XCTAssertTrue(JoplinCrypto.isEncrypted(fresh.wrapped))
        XCTAssertNotEqual(fresh.wrapped, fresh.master)
        // The wrapped copy must not contain the master in the clear.
        XCTAssertFalse(fresh.wrapped.contains(fresh.master))
    }

    /// The passphrase must be able to unwrap the key again.
    func testUnwrapReturnsTheSameMaster() throws {
        let fresh = try JoplinVaultKeyMaterial.create(passphrase: "a test passphrase")
        let reopened = try JoplinVaultKeyMaterial.unwrap(envelope: fresh.wrapped, passphrase: "a test passphrase")
        XCTAssertEqual(reopened.master, fresh.master)
        XCTAssertEqual(reopened.id, fresh.id)
    }

    /// A wrong passphrase must fail, not return garbage.
    func testWrongPassphraseFails() throws {
        let fresh = try JoplinVaultKeyMaterial.create(passphrase: "a test passphrase")
        XCTAssertThrowsError(try JoplinVaultKeyMaterial.unwrap(envelope: fresh.wrapped, passphrase: "another passphrase"))
    }

    /// A short passphrase is refused before any key is made.
    func testShortPassphraseRejected() {
        XCTAssertThrowsError(try JoplinVaultKeyMaterial.create(passphrase: "short")) { error in
            XCTAssertEqual(error as? JoplinVaultKeyMaterial.VaultError, .passphraseTooShort)
        }
    }

    // MARK: - Seal / open

    /// A sealed string must carry the envelope header and come back exactly.
    func testSealOpenRoundTrip() throws {
        let key = try material()
        let sealed = try JoplinVaultKeyMaterial.seal("hello notes", with: key)
        XCTAssertTrue(JoplinCrypto.isEncrypted(sealed))
        XCTAssertEqual(try JoplinVaultKeyMaterial.open(sealed, with: key), "hello notes")
    }

    /// Unicode must survive the UTF-16LE round trip.
    func testSealOpenUnicode() throws {
        let key = try material()
        let text = "Emoji 🔐 — “curly” · 日本語"
        let sealed = try JoplinVaultKeyMaterial.seal(text, with: key)
        XCTAssertEqual(try JoplinVaultKeyMaterial.open(sealed, with: key), text)
    }

    // MARK: - The notes file

    /// A plain file must pass through untouched — a library that never
    /// enabled encryption must not change shape.
    func testPlainFileIsUntouched() throws {
        let payload = Data("[{\"id\":\"00000000-0000-0000-0000-000000000000\"}]".utf8)
        let file = JoplinNotesFile.read(payload)
        XCTAssertFalse(file.isSealed)
        XCTAssertEqual(try JoplinNotesFile.payload(from: file, key: nil), payload)
    }

    /// A sealed file must round-trip through the file shape.
    func testSealedFileRoundTrip() throws {
        let key = try material()
        let payload = Data("[]".utf8)
        let sealed = try JoplinNotesFile.seal(payload, key: key)
        XCTAssertTrue(sealed.isSealed)
        let reread = JoplinNotesFile.read(sealed.encoded)
        XCTAssertTrue(reread.isSealed)
        XCTAssertEqual(try JoplinNotesFile.payload(from: reread, key: key), payload)
    }

    /// A sealed file with no key must refuse to open — it must NOT fall
    /// back to "the bytes as they are".
    func testSealedFileWithoutKeyRefuses() throws {
        let key = try material()
        let sealed = try JoplinNotesFile.seal(Data("[]".utf8), key: key)
        XCTAssertThrowsError(try JoplinNotesFile.payload(from: sealed, key: nil)) { error in
            XCTAssertEqual(error as? JoplinNotesFile.FileError, .sealedWithoutKey)
        }
    }

    /// The shape is decided by the FIRST BYTES. A plain file that merely
    /// mentions the header further down is still plain.
    func testShapeDetectionUsesFirstBytesOnly() {
        let payload = Data("plain text that mentions JED01 somewhere in the middle".utf8)
        XCTAssertFalse(JoplinNotesFile.read(payload).isSealed)
    }

    /// Two different vaults must not open each other's file.
    func testAnotherKeyCannotOpen() throws {
        let one = try material()
        let other = try JoplinVaultKeyMaterial.create(passphrase: "a different passphrase")
        let sealed = try JoplinNotesFile.seal(Data("secret".utf8), key: one)
        XCTAssertThrowsError(try JoplinNotesFile.payload(from: sealed, key: other))
    }
}
