import CryptoKit
import Foundation

/// The key material of one encryption vault, and the operations on it.
///
/// The passphrase KDF is 220 000 PBKDF2-HMAC-SHA512 iterations BY DESIGN —
/// that slowness is what makes a stolen file useless. It is deliberately
/// NOT tied to any actor here: the caller runs it on whatever thread it
/// likes (a background task on a UI, a plain call in a test) and gets a
/// VALUE back, so the expensive work never has to touch the main thread.
///
/// The material has three parts:
///
/// * `master` — the master key: 256 random bytes as 512 hex characters.
///   PLAINTEXT, in memory only, never written to disk.
/// * `id` — the 32-hex id that appears in every envelope sealed with this
///   key, so a store holding several keys can route a decryption to the
///   right one (Joplin supports several; the app has one).
/// * `wrapped` — the passphrase-protected copy (Joplin's KeyV1). This is
///   the ONLY part that ever reaches the disk (the keychain), and it is
///   useless without the passphrase.
public enum JoplinVaultKeyMaterial: Sendable {

    /// One vault's key material.
    public struct Material: Sendable, Equatable {
        /// The master key: 256 random bytes as 512 hex characters.
        public let master: String
        /// The 32-hex id that appears in every envelope sealed with this key.
        public let id: String
        /// The passphrase-wrapped master key (Joplin's KeyV1).
        public let wrapped: String

        public init(master: String, id: String, wrapped: String) {
            self.master = master
            self.id = id
            self.wrapped = wrapped
        }
    }

    /// The errors this type reports.
    public enum VaultError: Error, Equatable, CustomStringConvertible {
        case locked
        case passphraseTooShort
        case noKeyOnDevice
        case wrongPassphrase

        public var description: String {
            switch self {
            case .locked: return "The vault is locked."
            case .passphraseTooShort: return "Use a passphrase of at least 8 characters."
            case .noKeyOnDevice: return "No encryption key on this device."
            case .wrongPassphrase: return "That passphrase doesn't match."
            }
        }
    }

    /// Generates a fresh master key and wraps it with the passphrase.
    ///
    /// The passphrase must be at least 8 characters — the same floor the
    /// app enforces — so a caller that forgets the check fails HERE
    /// rather than sealing a library with a one-character key.
    public static func create(passphrase: String) throws -> Material {
        guard passphrase.count >= 8 else { throw VaultError.passphraseTooShort }
        let master = JoplinCrypto.makeMasterKey()
        let id = JoplinCrypto.makeMasterKeyId()
        let wrapped = try JoplinCrypto.encryptMasterKey(master, password: passphrase, masterKeyId: id)
        return Material(master: master, id: id, wrapped: wrapped)
    }

    /// Unwraps a stored master key with the passphrase.
    public static func unwrap(envelope: String, passphrase: String) throws -> Material {
        let master = try JoplinCrypto.decryptMasterKey(envelope, password: passphrase)
        let id = JoplinCrypto.masterKeyId(of: envelope) ?? ""
        return Material(master: master, id: id, wrapped: envelope)
    }

    /// Seals text with the material (Joplin's StringV1).
    public static func seal(_ text: String, with material: Material) throws -> String {
        try JoplinCrypto.encryptString(text, masterKeyHex: material.master, masterKeyId: material.id)
    }

    /// Opens an envelope with the material.
    public static func open(_ envelope: String, with material: Material) throws -> String {
        try JoplinCrypto.decryptString(envelope, masterKeyHex: material.master)
    }
}
