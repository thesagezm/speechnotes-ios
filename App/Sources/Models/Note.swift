import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// User-set title. nil (or blank) → title derives from the first line of
    /// `text`, which is how every note worked before v1.1.
    var explicitTitle: String?
    var text: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, explicitTitle, text, createdAt, updatedAt
    }

    init() {}

    /// Decodes notes.json written by older versions (no explicitTitle key)
    /// and tolerates missing fields entirely.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        explicitTitle = try c.decodeIfPresent(String.self, forKey: .explicitTitle)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var title: String {
        if let explicit = explicitTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return String(explicit.prefix(120))
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled note" : String(trimmed.prefix(60))
    }
}
