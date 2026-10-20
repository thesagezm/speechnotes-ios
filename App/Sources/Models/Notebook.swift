import Foundation

/// A flat notebook (Joplin-style folder) that notes can be filed into.
/// Hierarchy can be added later by giving Notebook a `parentId` — the JSON
/// layout already supports it without migration.
struct Notebook: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// The user's chosen position in the list. nil means "never moved" —
    /// those sort by `createdAt` after every explicitly-placed notebook, so an
    /// existing library keeps its order until the first reorder, and the
    /// first reorder only stamps what it must.
    var order: Int?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), order: Int? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // Absent in every file written before reordering existed.
        order = try c.decodeIfPresent(Int.self, forKey: .order)
    }
}
