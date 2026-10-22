import Foundation
import SpeechLogic

/// The app's notes-file layer: the generic file shape (plain JSON or one
/// Joplin StringV1 envelope) comes from `JoplinNotesFile` in SpeechLogic;
/// this type adds the one thing that is app-specific — how a payload
/// decodes into `Note` values and back.
enum NotesFileSealer {

    enum SealError: Error, Equatable, CustomStringConvertible {
        case plaintextNotJSON

        var description: String {
            switch self {
            case .plaintextNotJSON: return "The decrypted notes are not valid JSON."
            }
        }
    }

    /// The notes a file image holds. A plain file decodes directly; a
    /// sealed file is opened with the key material first.
    static func notes(from file: JoplinNotesFile, key: JoplinVaultKeyMaterial.Material?) throws -> [Note] {
        let payload = try JoplinNotesFile.payload(from: file, key: key)
        do {
            return try JSONDecoder().decode([Note].self, from: payload)
        } catch {
            throw SealError.plaintextNotJSON
        }
    }

    /// The file image the writer should persist for a set of notes. With a
    /// key, the file becomes an envelope; without one it stays plain.
    static func seal(_ notes: [Note], key: JoplinVaultKeyMaterial.Material?) throws -> JoplinNotesFile {
        let json = try JSONEncoder().encode(notes)
        return try JoplinNotesFile.seal(json, key: key)
    }
}
