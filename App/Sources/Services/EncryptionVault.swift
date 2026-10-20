import Foundation

/// The vault that holds this device's Joplin-compatible encryption keys.
///
/// TWO layers, exactly as Joplin does it:
///
/// * The **master key** is 256 random bytes; the user's passphrase wraps it
///   (Joplin's KeyV1) and the wrapped copy is what gets stored. The
///   passphrase itself is NEVER stored — only a verifier derived from it,
///   so a wrong passphrase can be detected without keeping the secret.
/// * The **master key id** is the 32-hex id that appears in every
///   encrypted envelope, so a vault can hold more than one key (Joplin
///   supports several) and still route a decryption to the right one.
///
/// The passphrase-protected master key lives in the KEYCHAIN (a
/// `kSecClassGenericPassword` item), never in a file. The keychain is the
/// only thing standing between a stolen device and the notes, so the
/// wrapped master key is stored there with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — usable by
/// background work after the first unlock, and never restored to another
/// device by a backup.
@MainActor
final class EncryptionVault: ObservableObject {
    static let shared = EncryptionVault()

    /// The keychain service + account the wrapped master key is stored under.
    private static let service = "com.speechnotes.vault"
    private static let account = "joplin-master-key"

    /// Whether this device holds an encryption key.
    @Published private(set) var isEnabled: Bool = false
    /// Whether a passphrase has been entered in THIS session (the key is
    /// decrypted in memory until the app locks).
    @Published private(set) var isUnlocked: Bool = false
    /// The last error, for the settings screen to show.
    @Published private(set) var lastError: String?

    /// The decrypted master key, in memory only, for as long as the app is
    /// unlocked. Never written to disk in this form.
    private var masterKeyHex: String?
    private var masterKeyId: String?

    private init() {
        isEnabled = KeychainStore.hasItem(service: Self.service, account: Self.account)
    }

    // MARK: - Public API

    /// Turns encryption on: generates a master key, wraps it with the
    /// passphrase, stores the wrapped key in the keychain and keeps the
    /// plaintext in memory. The caller re-encrypts the library afterwards.
    func enable(passphrase: String) throws {
        guard passphrase.count >= 8 else {
            throw VaultError.passphraseTooShort
        }
        let master = JoplinCrypto.makeMasterKey()
        let id = JoplinCrypto.makeMasterKeyId()
        let wrapped = try JoplinCrypto.encryptMasterKey(master, password: passphrase, masterKeyId: id)
        try KeychainStore.set(
            Data(wrapped.utf8),
            service: Self.service,
            account: Self.account
        )
        masterKeyHex = master
        masterKeyId = id
        isEnabled = true
        isUnlocked = true
        lastError = nil
    }

    /// Turns encryption off: removes the key from the keychain and drops
    /// the in-memory key. The caller must re-encrypt the library in
    /// PLAINTEXT afterwards, or the notes stay unreadable.
    func disable() {
        try? KeychainStore.delete(service: Self.service, account: Self.account)
        masterKeyHex = nil
        masterKeyId = nil
        isEnabled = false
        isUnlocked = false
    }

    /// Unlocks the vault with the passphrase. Returns false when the
    /// passphrase is wrong.
    @discardableResult
    func unlock(passphrase: String) -> Bool {
        guard let wrapped = KeychainStore.get(service: Self.service, account: Self.account),
              let text = String(data: wrapped, encoding: .utf8) else {
            lastError = "No encryption key on this device."
            return false
        }
        do {
            let master = try JoplinCrypto.decryptMasterKey(text, password: passphrase)
            masterKeyHex = master
            masterKeyId = JoplinCrypto.decodeHeader(text).masterKeyId
            isUnlocked = true
            lastError = nil
            return true
        } catch {
            lastError = "That passphrase doesn't match."
            return false
        }
    }

    /// Locks the vault: the in-memory key is dropped.
    func lock() {
        masterKeyHex = nil
        masterKeyId = nil
        isUnlocked = false
    }

    /// The master key id (32 hex chars), or nil when there is no key.
    var keyId: String? { masterKeyId }

    /// Encrypts a note's text with the current master key. Throws when the
    /// vault is locked — callers must not silently write plaintext.
    func encrypt(_ text: String) throws -> String {
        guard let master = masterKeyHex, let id = masterKeyId else {
            throw VaultError.locked
        }
        return try JoplinCrypto.encryptString(text, masterKeyHex: master, masterKeyId: id)
    }

    /// Decrypts a note's text. Throws when the vault is locked or the text
    /// is not an encrypted envelope.
    func decrypt(_ text: String) throws -> String {
        guard let master = masterKeyHex else { throw VaultError.locked }
        return try JoplinCrypto.decryptString(text, masterKeyHex: master)
    }

    /// True when the text carries an encrypted envelope header.
    func isEncrypted(_ text: String) -> Bool {
        JoplinCrypto.isEncrypted(text)
    }

    enum VaultError: Error, Equatable, CustomStringConvertible {
        case locked
        case passphraseTooShort

        var description: String {
            switch self {
            case .locked: return "The vault is locked."
            case .passphraseTooShort: return "Use a passphrase of at least 8 characters."
            }
        }
    }
}

/// A very small Keychain wrapper: one generic-password item, device-only,
/// readable after the first unlock (background work must be able to
/// decrypt, e.g. a note that is spoken while the phone is locked).
enum KeychainStore {
    static func hasItem(service: String, account: String) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func set(_ data: Data, service: String, account: String) -> Bool {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query = baseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
