import Foundation

/// The on-disk shape of a notes file, and the seal/open operations on it.
///
/// Plain JSON is the historical (and default) form: the bytes of a notes
/// array, exactly as every version before encryption wrote it. Once the
/// user turns encryption on, the file becomes one Joplin StringV1 envelope
/// whose plaintext is those same bytes — so enabling, disabling and
/// re-enabling encryption all keep ONE format underneath, and the decrypted
/// bytes are byte-identical to what the plain writer produced.
///
/// The type is deliberately generic over the payload (bytes, not `Note`):
/// the app's notes model lives in the app target, and the crypto shape
/// belongs here where it can be tested.
public enum JoplinNotesFile: Equatable {
    /// The plain payload, unprotected.
    case plain(Data)
    /// One Joplin StringV1 envelope; its plaintext is the payload.
    case sealed(String)

    /// The errors this type reports.
    public enum FileError: Error, Equatable, CustomStringConvertible {
        case sealedWithoutKey
        case plaintextNotUTF8

        public var description: String {
            switch self {
            case .sealedWithoutKey: return "This file is encrypted, but no key is available."
            case .plaintextNotUTF8: return "The decrypted contents are not valid text."
            }
        }
    }

    /// Reads a file, deciding which shape it is from the leading envelope
    /// header — never from a flag stored elsewhere (a flag can drift; the
    /// bytes cannot).
    ///
    /// The shape is detected from the FIRST BYTES, not by decoding the
    /// whole file to a String: a 10 MB library must not be copied into a
    /// String just to learn it is plain JSON.
    public static func read(_ data: Data) -> JoplinNotesFile {
        if data.count >= 5,
           let prefix = String(data: data.prefix(5), encoding: .utf8),
           prefix == "JED01" || prefix == "JED02" {
            return .sealed(String(decoding: data, as: UTF8.self))
        }
        return .plain(data)
    }

    public var isSealed: Bool {
        if case .sealed = self { return true }
        return false
    }

    /// The bytes to write. A sealed file is the envelope's UTF-8; a plain
    /// one is the payload itself.
    public var encoded: Data {
        switch self {
        case .plain(let data): return data
        case .sealed(let text): return Data(text.utf8)
        }
    }

    /// Seals a payload with the key material. Without a key the payload
    /// stays plain — which is what a user with encryption OFF gets, and
    /// what a user who locked the app keeps (the last plaintext file stays
    /// as it is).
    public static func seal(_ payload: Data, key: JoplinVaultKeyMaterial.Material?) throws -> JoplinNotesFile {
        guard let key else { return .plain(payload) }
        guard let text = String(data: payload, encoding: .utf8) else { throw FileError.plaintextNotUTF8 }
        let envelope = try JoplinVaultKeyMaterial.seal(text, with: key)
        return .sealed(envelope)
    }

    /// Opens a file image and returns the payload it holds. A plain file
    /// returns its bytes untouched, so a library that never enabled
    /// encryption is unaffected by the feature.
    public static func payload(from file: JoplinNotesFile, key: JoplinVaultKeyMaterial.Material?) throws -> Data {
        switch file {
        case .plain(let plain):
            return plain
        case .sealed(let envelope):
            guard let key else { throw FileError.sealedWithoutKey }
            let text = try JoplinVaultKeyMaterial.open(envelope, with: key)
            guard let bytes = text.data(using: .utf8) else { throw FileError.plaintextNotUTF8 }
            return bytes
        }
    }
}
