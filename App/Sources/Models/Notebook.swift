import Foundation

/// A flat notebook (Joplin-style folder) that notes can be filed into.
/// Hierarchy can be added later by giving Notebook a `parentId` — the JSON
/// layout already supports it without migration.
struct Notebook: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
