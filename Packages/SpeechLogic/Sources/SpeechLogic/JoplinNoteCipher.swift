import Foundation

/// The note CONTENT that Joplin encrypts, and the two shapes it is sealed
/// into.
///
/// A note's sensitive parts are its title and its body. Everything else
/// (id, timestamps, notebook, pin/favourite) stays in the clear, exactly as
/// Joplin does it — its own sync keeps `id`, `parent_id`, `updated_time`,
/// `deleted_time` and `type_` outside the ciphertext so items can still be
/// linked and ordered.
public struct JoplinNoteContent: Codable, Equatable {
    public var title: String?
    public var body: String

    public init(title: String?, body: String) {
        self.title = title
        self.body = body
    }
}

/// Seals note content with Joplin's own format.
///
/// Two seals, two shapes, one envelope format:
///
/// * **Content seal** — the app's own storage. The plaintext is a small
///   JSON object (`{"title":…,"body":…}`) sealed with StringV1. Used for
///   the notes file, so a locked device's notes file is unreadable
///   without the passphrase.
/// * **Item seal** — the JEX export. The plaintext is Joplin's own item
///   serialization (`title\n\nbody\n\nkey: value…`), the exact text Joplin
///   encrypts for sync. A .jex written this way imports into Joplin as an
///   ENCRYPTED item, which is what makes the round trip real.
public enum JoplinNoteCipher {

    /// The JSON keys of the content seal. Kept short because the sealed
    /// base64 grows by ~4/3 of the plaintext.
    private enum ContentKeys: String, CodingKey {
        case title, body
    }

    // MARK: - Content seal (the app's own storage)

    /// Seals a note's title and body into one Joplin StringV1 envelope.
    public static func sealContent(
        _ content: JoplinNoteContent,
        masterKeyHex: String,
        masterKeyId: String
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(content)
        // The plaintext is UTF-8 JSON here (not the UTF-16LE Joplin uses for
        // note text) — the envelope format does not care, only the bytes
        // do, and both sides of this format are this app.
        let plaintext = String(decoding: json, as: UTF8.self)
        return try JoplinCrypto.encryptString(plaintext, masterKeyHex: masterKeyHex, masterKeyId: masterKeyId)
    }

    /// Opens a content seal.
    public static func openContent(
        _ envelope: String,
        masterKeyHex: String
    ) throws -> JoplinNoteContent {
        let plaintext = try JoplinCrypto.decryptString(envelope, masterKeyHex: masterKeyHex)
        guard let data = plaintext.data(using: .utf8) else {
            throw JoplinCrypto.CryptoError.malformedEnvelope
        }
        return try JSONDecoder().decode(JoplinNoteContent.self, from: data)
    }

    // MARK: - Item seal (the JEX export)

    /// Joplin's item serialization — the text its own exporter writes into a
    /// `.md` entry: the title, then the body, then the `key: value` props,
    /// each group separated by a blank line.
    public static func joplinItem(
        title: String,
        body: String,
        props: [(String, String)]
    ) -> String {
        var parts: [String] = []
        parts.append(title)
        if !body.isEmpty { parts.append(body) }
        if !props.isEmpty {
            parts.append(props.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The props of a Joplin note item, in the order Joplin writes them.
    public static func noteProps(
        id: String,
        parentId: String?,
        createdAt: Date,
        updatedAt: Date
    ) -> [(String, String)] {
        var props: [(String, String)] = [("id", id)]
        if let parentId { props.append(("parent_id", parentId)) }
        props.append(("created_time", isoTimestamp(createdAt)))
        props.append(("updated_time", isoTimestamp(updatedAt)))
        props.append(("markup_language", "1")) // 1 = markdown
        return props
    }

    /// Seals a Joplin item into an envelope — the ciphertext that a .jex
    /// entry carries as `encryption_cipher_text`.
    public static func sealItem(
        title: String,
        body: String,
        props: [(String, String)],
        masterKeyHex: String,
        masterKeyId: String
    ) throws -> String {
        let item = joplinItem(title: title, body: body, props: props)
        return try JoplinCrypto.encryptString(item, masterKeyHex: masterKeyHex, masterKeyId: masterKeyId)
    }

    /// Opens a sealed Joplin item: the title, the body and the props.
    public static func openItem(
        _ envelope: String,
        masterKeyHex: String
    ) throws -> (title: String, body: String, props: [String: String]) {
        let item = try JoplinCrypto.decryptString(envelope, masterKeyHex: masterKeyHex)
        return parseJoplinItem(item)
    }

    /// Splits a Joplin item serialization back into its parts. The
    /// separator is the blank line; the props are the trailing
    /// `key: value` lines.
    public static func parseJoplinItem(_ item: String) -> (title: String, body: String, props: [String: String]) {
        let blocks = item.components(separatedBy: "\n\n")
        var title = ""
        var body = ""
        var props: [String: String] = [:]

        for (index, block) in blocks.enumerated() {
            let isProps = block.split(separator: "\n", omittingEmptySubsequences: false)
                .allSatisfy { line in
                    line.isEmpty || line.contains(": ")
                }
            if isProps, !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for line in block.components(separatedBy: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { props[key] = value }
                }
            } else if index == 0 {
                title = block
            } else if body.isEmpty {
                body = block
            } else {
                body += "\n\n" + block
            }
        }
        return (title, body, props)
    }

    // MARK: - Shared

    /// ISO-8601 with milliseconds — the timestamp shape Joplin writes.
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isoTimestamp(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}
