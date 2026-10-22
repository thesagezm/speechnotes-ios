import CryptoKit
import Foundation
import Security

/// Joplin's end-to-end encryption, reimplemented from the format Joplin
/// itself uses (packages/lib/services/e2ee/EncryptionService.ts and
/// crypto.ts, Joplin v3.2+). No Joplin code was copied or repurposed — this
/// is an independent implementation of the same on-disk format, so a note
/// encrypted here can be decrypted there and vice versa.
///
/// The two methods that matter for notes:
///
/// * **KeyV1** (method 8) wraps the MASTER KEY with the user's passphrase:
///   PBKDF2-HMAC-SHA512(passphrase, salt, 220 000 iterations) → AES-256-GCM
///   over the master key's 256 raw bytes. The 220 000 count is Joplin's
///   (OWASP-suggested) value and the reason a passphrase unlock is slow on
///   purpose.
/// * **StringV1** (method 10) encrypts a note's text with a DATA KEY
///   derived from the master key: PBKDF2-HMAC-SHA512(masterKeyHex, salt, 3
///   iterations) → AES-256-GCM over the UTF-16LE bytes of the text. The
///   iteration count is 3 because the master key already carries the
///   entropy.
///
/// Both wrap their result in the same envelope:
///
///     JED01 <6 hex: metadata length> <metadata> <chunks…>
///     metadata = <2 hex: method> <32 hex: master key id>
///     chunk    = <6 hex: length> {"salt":…,"iv":…,"ct":…}
///
/// where the chunk JSON holds the base64 salt (SHA-256 of the session
/// nonce), the 96-bit IV and the ciphertext-with-auth-tag. The salt lives
/// inside the envelope, so an envelope is self-contained: it can be
/// decrypted later, on another device, with only the master key.
public enum JoplinCrypto {

    /// The encryption methods Joplin defines for this format.
    public enum Method: Int, CaseIterable, Equatable {
        /// Wraps a master key with a passphrase.
        case keyV1 = 8
        /// Encrypts a file/resource payload (base64 plaintext).
        case fileV1 = 9
        /// Encrypts a note's text (UTF-16LE plaintext).
        case stringV1 = 10
    }

    public enum CryptoError: Error, Equatable, CustomStringConvertible {
        case malformedEnvelope
        case unsupportedMethod(Int)
        case badPassword
        case badMasterKey

        public var description: String {
            switch self {
            case .malformedEnvelope: return "The encrypted data is malformed."
            case .unsupportedMethod(let m): return "Encryption method \(m) is not supported."
            case .badPassword: return "Wrong passphrase."
            case .badMasterKey: return "The master key is not valid."
            }
        }
    }

    // MARK: - Constants (Joplin's own)

    /// PBKDF2 iteration count for the passphrase → master-key path.
    static let keyV1Iterations = 220_000
    /// PBKDF2 iteration count for the master-key → data-key path.
    static let stringV1Iterations = 3
    /// Master key length in bytes (Joplin generates 256).
    static let masterKeyBytes = 256
    /// Joplin's chunk size for StringV1, in UTF-16 code units.
    static let stringV1ChunkUnits = 65_536
    /// The session nonce is 36 bytes: random (21) + timestamp (7) + counter (8).
    static let nonceLength = 36
    /// The counter lives in the last 8 bytes of the nonce.
    static let nonceCounterLength = 8
    /// The timestamp occupies 7 bytes before the counter.
    static let nonceTimestampLength = 7

    // MARK: - Public API

    /// A fresh master key: 256 random bytes as 512 lowercase hex characters —
    /// the exact shape Joplin stores (it is a HEX STRING, and the string
    /// itself is what the data-key PBKDF2 consumes).
    public static func makeMasterKey() -> String {
        let bytes = randomBytes(masterKeyBytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A master key id in Joplin's shape: 32 lowercase hex characters (Joplin
    /// uses an undashed uuid v4 for this).
    public static func makeMasterKeyId() -> String {
        var bytes = Array(randomBytes(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Wraps a master key with a passphrase (Joplin's KeyV1).
    public static func encryptMasterKey(
        _ masterKeyHex: String,
        password: String,
        masterKeyId: String
    ) throws -> String {
        guard let raw = hexBytes(masterKeyHex), raw.count == masterKeyBytes else {
            throw CryptoError.badMasterKey
        }
        return try seal(
            plaintext: raw,
            password: Data(password.utf8),
            method: .keyV1,
            masterKeyId: masterKeyId,
            iterations: keyV1Iterations,
            keyLength: 32
        )
    }

    /// Unwraps a master key with a passphrase.
    public static func decryptMasterKey(_ envelope: String, password: String) throws -> String {
        let opened = try open(envelope, password: Data(password.utf8), method: .keyV1, iterations: keyV1Iterations, keyLength: 32)
        return opened.map { String(format: "%02x", $0) }.joined()
    }

    /// Encrypts a note's text with the master key (Joplin's StringV1).
    public static func encryptString(
        _ text: String,
        masterKeyHex: String,
        masterKeyId: String
    ) throws -> String {
        return try seal(
            plaintext: utf16LEBytes(text),
            password: Data(masterKeyHex.utf8),
            method: .stringV1,
            masterKeyId: masterKeyId,
            iterations: stringV1Iterations,
            keyLength: 32
        )
    }

    /// Decrypts a note's text with the master key.
    public static func decryptString(_ envelope: String, masterKeyHex: String) throws -> String {
        let opened = try open(
            envelope,
            password: Data(masterKeyHex.utf8),
            method: .stringV1,
            iterations: stringV1Iterations,
            keyLength: 32
        )
        return utf16LEString(opened)
    }

    /// A string's UTF-16LE bytes — the exact shape Joplin encrypts (its
    /// `utf16le` encoder). The byte order is spelled out rather than left
    /// to the host's endianness, because the bytes travel to a device that
    /// may be the other way round.
    static func utf16LEBytes(_ text: String) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.utf16.count * 2)
        for unit in text.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8((unit >> 8) & 0xFF))
        }
        return bytes
    }

    /// The inverse of `utf16LEBytes`.
    static func utf16LEString(_ bytes: [UInt8]) -> String {
        var units = [UInt16]()
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// True when the string carries Joplin's encrypted-data header. Used to
    /// tell an encrypted note from a plain one without decrypting it.
    public static func isEncrypted(_ text: String) -> Bool {
        text.hasPrefix("JED01") || text.hasPrefix("JED02")
    }

    /// The master key id an envelope was sealed with, read from the header
    /// alone — no key needed. This is how a vault holding several keys
    /// routes a decryption to the right one, and how the app recovers the
    /// id of the key it just unwrapped.
    public static func masterKeyId(of envelope: String) -> String? {
        guard let header = try? decodeHeader(envelope) else { return nil }
        return header.masterKeyId
    }

    // MARK: - Envelope

    /// The header: `JED01` + 6 hex digits of metadata length + the metadata
    /// (2 hex digits of method + 32 hex digits of master key id).
    static func encodeHeader(method: Method, masterKeyId: String) -> String {
        let metadata = String(format: "%02x", method.rawValue) + masterKeyId
        return "JED01" + String(format: "%06x", metadata.count) + metadata
    }

    /// Parses the header, returning the method, the master key id and the
    /// offset where the chunks start.
    static func decodeHeader(_ text: String) throws -> (method: Method, masterKeyId: String, chunksStart: Int) {
        let identifier = String(text.prefix(5))
        guard identifier == "JED01" || identifier == "JED02" else {
            throw CryptoError.malformedEnvelope
        }
        let lengthHex = String(text.dropFirst(5).prefix(6))
        guard lengthHex.count == 6, let length = Int(lengthHex, radix: 16), length > 0 else {
            throw CryptoError.malformedEnvelope
        }
        let metadataStart = 11
        let metadata = String(text.dropFirst(metadataStart).prefix(length))
        guard metadata.count == length, metadata.count >= 34 else {
            throw CryptoError.malformedEnvelope
        }
        let methodHex = String(metadata.prefix(2))
        guard let methodValue = Int(methodHex, radix: 16), let method = Method(rawValue: methodValue) else {
            throw CryptoError.unsupportedMethod(Int(methodHex, radix: 16) ?? -1)
        }
        let masterKeyId = String(metadata.dropFirst(2))
        guard masterKeyId.count == 32 else { throw CryptoError.malformedEnvelope }
        return (method, masterKeyId, metadataStart + length)
    }

    // MARK: - Seal / open

    /// Encrypts and writes one envelope.
    ///
    /// `plaintext` arrives already in the method's byte shape: raw bytes for
    /// KeyV1, UTF-16 code units for StringV1. The chunking follows Joplin's
    /// (StringV1: 65 536 code units per chunk), so a long note splits the
    /// same way Joplin would split it.
    private static func seal(
        plaintext: [UInt8],
        password: Data,
        method: Method,
        masterKeyId: String,
        iterations: Int,
        keyLength: Int
    ) throws -> String {
        let nonce = makeNonce()
        let salt = Data(SHA256.hash(data: nonce))
        let key = try deriveKey(password: password, salt: salt, iterations: iterations, keyLength: keyLength)
        let chunkUnits = method == .stringV1 ? stringV1ChunkUnits * 2 : max(plaintext.count, 1)

        var out = encodeHeader(method: method, masterKeyId: masterKeyId)
        var cursor = 0
        while cursor < plaintext.count {
            let end = min(cursor + chunkUnits, plaintext.count)
            let chunk = Array(plaintext[cursor..<end])
            cursor = end
            let iv = Data(randomBytes(12))
            let sealed = try AES.GCM.seal(
                Data(chunk),
                using: SymmetricKey(data: key),
                nonce: try aesNonce(iv),
                authenticating: Data()
            )
            var ciphertext = Data(sealed.ciphertext)
            ciphertext.append(contentsOf: sealed.tag)
            let json = chunkJSON(salt: salt, iv: iv, ciphertext: ciphertext)
            out += String(format: "%06x", json.utf8.count)
            out += json
        }
        return out
    }

    /// Decrypts one envelope.
    private static func open(
        _ text: String,
        password: Data,
        method: Method,
        iterations: Int,
        keyLength: Int
    ) throws -> [UInt8] {
        let header = try decodeHeader(text)
        guard header.method == method else {
            throw CryptoError.unsupportedMethod(header.method.rawValue)
        }
        // The envelope is ASCII (base64 payloads and hex counters), so UTF-8
        // byte offsets and character offsets agree — but bytes are the
        // format's own unit, so slice on bytes.
        let bytes = Array(text.utf8)
        var output = [UInt8]()
        var cursor = header.chunksStart
        while cursor < bytes.count {
            let lengthHex = String(decoding: bytes[cursor..<min(cursor + 6, bytes.count)], as: UTF8.self)
            guard lengthHex.count == 6, let length = Int(lengthHex, radix: 16) else {
                throw CryptoError.malformedEnvelope
            }
            cursor += 6
            guard cursor + length <= bytes.count else { throw CryptoError.malformedEnvelope }
            let json = String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
            let chunk = try decryptChunk(
                json,
                password: password,
                iterations: iterations,
                keyLength: keyLength
            )
            output.append(contentsOf: chunk)
        }
        return output
    }

    /// One chunk: `{"salt":…,"iv":…,"ct":…}` → plaintext bytes.
    private static func decryptChunk(
        _ json: String,
        password: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> [UInt8] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let saltString = object["salt"],
              let ivString = object["iv"],
              let ciphertextString = object["ct"],
              let salt = Data(base64Encoded: saltString),
              let iv = Data(base64Encoded: ivString),
              let ciphertext = Data(base64Encoded: ciphertextString)
        else { throw CryptoError.malformedEnvelope }

        let key = try deriveKey(password: password, salt: salt, iterations: iterations, keyLength: keyLength)
        // CryptoKit's GCM box is ciphertext || tag.
        guard ciphertext.count > 16 else { throw CryptoError.malformedEnvelope }
        let box = try AES.GCM.SealedBox(
            nonce: try aesNonce(iv),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16)
        )
        do {
            return Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data()))
        } catch {
            throw CryptoError.badPassword
        }
    }

    /// The chunk JSON, in Joplin's key order (salt, iv, ct) so the bytes
    /// match what Joplin writes.
    private static func chunkJSON(salt: Data, iv: Data, ciphertext: Data) -> String {
        let payload: [String: String] = [
            "salt": salt.base64EncodedString(),
            "iv": iv.base64EncodedString(),
            "ct": ciphertext.base64EncodedString()
        ]
        // JSONSerialization has no key-order control, so the object is
        // assembled by hand — the payload is three base64 strings, none of
        // which can contain a character JSON needs to escape.
        let parts = ["salt", "iv", "ct"].map { key in
            "\"\(key)\":\"\(payload[key] ?? "")\""
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    // MARK: - Key derivation

    /// PBKDF2-HMAC-SHA512. CryptoKit has no PBKDF2, so this is the standard
    /// construction over its HMAC: U1 = PRF(password, salt || INT(i)),
    /// Uc = PRF(password, U(c-1)), T = U1 xor U2 xor … .
    public static func deriveKey(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        let hLen = SHA512.byteCount
        let blocks = (keyLength + hLen - 1) / hLen
        let key = SymmetricKey(data: password)
        var derived = Data()
        derived.reserveCapacity(blocks * hLen)
        for block in 1...max(blocks, 1) {
            var saltBlock = salt
            var counter = UInt32(block).bigEndian
            withUnsafeBytes(of: &counter) { saltBlock.append(contentsOf: $0) }
            var u = Data(HMAC<SHA512>.authenticationCode(for: saltBlock, using: key))
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA512>.authenticationCode(for: u, using: key))
                    xor(&t, u)
                }
            }
            derived.append(t)
        }
        return derived.prefix(keyLength)
    }

    private static func xor(_ lhs: inout Data, _ rhs: Data) {
        let rhsBytes = Array(rhs)
        guard !rhsBytes.isEmpty else { return }
        lhs.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0..<min(raw.count, rhsBytes.count) {
                base[index] ^= rhsBytes[index]
            }
        }
    }

    // MARK: - Nonce / IV

    /// Joplin's session nonce: 21 random bytes, a 7-byte millisecond
    /// timestamp and an 8-byte counter. The salt is its SHA-256, so each
    /// envelope's data key is unique even under one master key.
    static func makeNonce() -> Data {
        var nonce = Data(randomBytes(nonceLength))
        // Timestamp: 4 low bytes then 3 high bytes (Joplin's own layout).
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        var littleEndian = timestamp
        for index in 0..<4 {
            nonce[nonceLength - nonceCounterLength - nonceTimestampLength + index] = UInt8(littleEndian & 0xFF)
            littleEndian >>= 8
        }
        var high = timestamp >> 32
        for index in 4..<nonceTimestampLength {
            nonce[nonceLength - nonceCounterLength - nonceTimestampLength + index] = UInt8(high & 0xFF)
            high >>= 8
        }
        // The counter (last 8 bytes) starts at zero.
        for index in (nonceLength - nonceCounterLength)..<nonceLength {
            nonce[index] = 0
        }
        return nonce
    }

    static func randomBytes(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            bytes = Array(SymmetricKey(size: SymmetricKeySize(bitCount: 8 * count)).withUnsafeBytes { Array($0) })
        }
        return Data(bytes)
    }

    private static func aesNonce(_ iv: Data) throws -> AES.GCM.Nonce {
        guard iv.count == 12 else { throw CryptoError.malformedEnvelope }
        return try AES.GCM.Nonce(data: iv)
    }

    // MARK: - Hex

    static func hexBytes(_ hex: String) -> [UInt8]? {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            let pair = String(characters[index..<(index + 2)])
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
    }
}
