import CryptoKit
import XCTest
@testable import SpeechLogic

/// The Joplin-compatible encryption format, checked against vectors produced
/// by an INDEPENDENT implementation (Python `hashlib.pbkdf2_hmac` +
/// `cryptography`'s AESGCM), so the Swift code is not merely self-consistent:
/// a note encrypted here decrypts in Joplin, and one encrypted there
/// decrypts here.
final class JoplinCryptoTests: XCTestCase {

    /// The vectors file, written by the Python oracle (see the batch notes:
    /// it is a TEST FIXTURE, not app data).
    private struct Vectors: Decodable {
        let pbkdf2_keyv1_hex: String
        let pbkdf2_stringv1_hex: String
        let salt_hex: String
        let keyv1_json: String
        let stringv1_json: String
        let keyv1_envelope: String
        let stringv1_envelope: String
        let stringv1_plaintext: String
        let master_hex: String
        let password: String
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "joplin-crypto-vectors", withExtension: "json", subdirectory: "Fixtures")
        let data = try Data(contentsOf: XCTUnwrap(url))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    // MARK: - Key derivation

    /// PBKDF2-HMAC-SHA512 must agree with the reference to the byte: the
    /// 220 000-iteration passphrase path is the whole reason unlocking is
    /// slow, so a wrong digest silently produces notes Joplin cannot read.
    func testPBKDF2MatchesReferenceVector() throws {
        let v = try vectors()
        let salt = Data(JoplinCrypto.hexBytes(v.salt_hex) ?? [])
        let key = JoplinCrypto.deriveKey(
            password: Data(v.password.utf8),
            salt: salt,
            iterations: 220_000,
            keyLength: 32
        )
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), v.pbkdf2_keyv1_hex)
    }

    /// The data-key path (3 iterations over the master key's hex string).
    func testDataKeyPBKDF2MatchesReferenceVector() throws {
        let v = try vectors()
        let salt = Data(JoplinCrypto.hexBytes(v.salt_hex) ?? [])
        let key = JoplinCrypto.deriveKey(
            password: Data(v.master_hex.utf8),
            salt: salt,
            iterations: 3,
            keyLength: 32
        )
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), v.pbkdf2_stringv1_hex)
    }

    // MARK: - Envelope

    /// A reference envelope must decrypt to the reference plaintext.
    func testDecryptsReferenceStringEnvelope() throws {
        let v = try vectors()
        let text = try JoplinCrypto.decryptString(v.stringv1_envelope, masterKeyHex: v.master_hex)
        XCTAssertEqual(text, v.stringv1_plaintext)
    }

    /// The reference master-key envelope must unwrap to the reference master
    /// key hex.
    func testDecryptsReferenceKeyEnvelope() throws {
        let v = try vectors()
        let master = try JoplinCrypto.decryptMasterKey(v.keyv1_envelope, password: v.password)
        XCTAssertEqual(master, v.master_hex)
    }

    /// The envelope header must decode to the right method and master key id.
    func testHeaderDecodes() throws {
        let v = try vectors()
        let header = try JoplinCrypto.decodeHeader(v.stringv1_envelope)
        XCTAssertEqual(header.method, .stringV1)
        XCTAssertEqual(header.masterKeyId, "0123456789abcdef0123456789abcdef")
        // The chunk table starts right after the metadata.
        XCTAssertEqual(String(v.stringv1_envelope.dropFirst(header.chunksStart).prefix(6)), "0000f3")
    }

    /// The chunk JSON must be exactly Joplin's shape: salt, iv, ct, all
    /// base64.
    func testChunkJSONShape() throws {
        let v = try vectors()
        let object = try JSONSerialization.jsonObject(with: Data(v.stringv1_json.utf8)) as? [String: String]
        let fields = try XCTUnwrap(object)
        XCTAssertEqual(Set(fields.keys), ["salt", "iv", "ct"])
        // The order matters for byte-compatibility with Joplin's writer.
        XCTAssertTrue(v.stringv1_json.hasPrefix("{\"salt\":"))
        XCTAssertTrue(v.stringv1_json.contains(",\"iv\":"))
        XCTAssertTrue(v.stringv1_json.contains(",\"ct\":"))
        // 96-bit IV.
        let iv = try XCTUnwrap(Data(base64Encoded: fields["iv"] ?? ""))
        XCTAssertEqual(iv.count, 12)
    }

    // MARK: - Round trip

    /// The app's own envelope must survive its own decryption, including a
    /// note long enough to need more than one chunk.
    func testRoundTripShortNote() throws {
        let master = JoplinCrypto.makeMasterKey()
        let id = JoplinCrypto.makeMasterKeyId()
        let text = "A short note."
        let envelope = try JoplinCrypto.encryptString(text, masterKeyHex: master, masterKeyId: id)
        XCTAssertTrue(JoplinCrypto.isEncrypted(envelope))
        XCTAssertEqual(try JoplinCrypto.decryptString(envelope, masterKeyHex: master), text)
    }

    /// A note longer than one chunk (65 536 UTF-16 units) must be split and
    /// reassembled in order.
    func testRoundTripLongNoteSpansChunks() throws {
        let master = JoplinCrypto.makeMasterKey()
        let id = JoplinCrypto.makeMasterKeyId()
        // 100 000 characters → two chunks.
        let text = String(repeating: "abcdefghij", count: 10_000)
        let envelope = try JoplinCrypto.encryptString(text, masterKeyHex: master, masterKeyId: id)
        // Two chunks → two length prefixes.
        XCTAssertGreaterThan(envelope.count, 100_000)
        XCTAssertEqual(try JoplinCrypto.decryptString(envelope, masterKeyHex: master), text)
    }

    /// Non-ASCII must survive: Joplin encodes note text as UTF-16LE, so
    /// emoji, quotes and CJK all have to round-trip exactly.
    func testRoundTripUnicode() throws {
        let master = JoplinCrypto.makeMasterKey()
        let id = JoplinCrypto.makeMasterKeyId()
        let text = "Emoji 🔐 — “curly quotes” · 日本語 · مرحبا"
        let envelope = try JoplinCrypto.encryptString(text, masterKeyHex: master, masterKeyId: id)
        XCTAssertEqual(try JoplinCrypto.decryptString(envelope, masterKeyHex: master), text)
    }

    // MARK: - Master key

    /// The master key round trip: wrap with a passphrase, unwrap it.
    func testMasterKeyRoundTrip() throws {
        let master = JoplinCrypto.makeMasterKey()
        XCTAssertEqual(master.count, 512)
        let id = JoplinCrypto.makeMasterKeyId()
        XCTAssertEqual(id.count, 32)
        let envelope = try JoplinCrypto.encryptMasterKey(master, password: "hunter2", masterKeyId: id)
        let unwrapped = try JoplinCrypto.decryptMasterKey(envelope, password: "hunter2")
        XCTAssertEqual(unwrapped, master)
    }

    /// A wrong passphrase must fail cleanly, not return garbage.
    func testWrongPassphraseFails() throws {
        let master = JoplinCrypto.makeMasterKey()
        let id = JoplinCrypto.makeMasterKeyId()
        let envelope = try JoplinCrypto.encryptMasterKey(master, password: "hunter2", masterKeyId: id)
        XCTAssertThrowsError(try JoplinCrypto.decryptMasterKey(envelope, password: "hunter3")) { error in
            XCTAssertEqual(error as? JoplinCrypto.CryptoError, .badPassword)
        }
    }

    /// A wrong master key must fail the same way.
    func testWrongMasterKeyFails() throws {
        let master = JoplinCrypto.makeMasterKey()
        let id = JoplinCrypto.makeMasterKeyId()
        let envelope = try JoplinCrypto.encryptString("secret", masterKeyHex: master, masterKeyId: id)
        XCTAssertThrowsError(try JoplinCrypto.decryptString(envelope, masterKeyHex: JoplinCrypto.makeMasterKey()))
    }

    /// Garbage must be rejected as malformed, not crash.
    func testMalformedEnvelopeRejected() {
        XCTAssertThrowsError(try JoplinCrypto.decodeHeader("not an envelope"))
        XCTAssertThrowsError(try JoplinCrypto.decodeHeader("JED01zzzzzz"))
        XCTAssertThrowsError(try JoplinCrypto.decryptString("", masterKeyHex: "ab"))
    }
}
