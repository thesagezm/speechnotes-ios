import Foundation
import SpeechLogic

/// The one place JEX archives get built. BackupExportView (Save/Share) and
/// the BookDrop send path used to each hand-roll the same note/notebook
/// tuple dance — one place now, so an export option added for the share
/// sheet is automatically available over BookDrop and vice versa.
enum JexExporter {
    /// Nonisolated: `JexExport` runs detached, and callers snapshot the
    /// stores on the main actor before calling in.
    nonisolated static func build(notes: [Note], notebooks: [Notebook]) async -> Data {
        await Task.detached(priority: .userInitiated) {
            let noteTuples: [(UUID, String, String, UUID?, Date, Date)] = notes.map {
                ($0.id, $0.title, $0.text, $0.notebookId, $0.createdAt, $0.updatedAt)
            }
            let notebookTuples: [(UUID, String, Date)] = notebooks.map {
                ($0.id, $0.name, $0.createdAt)
            }
            let (notePayloads, notebookPayloads) = JexExport.payloads(
                notes: noteTuples,
                notebooks: notebookTuples
            )
            return JexExport.buildArchive(notes: notePayloads, notebooks: notebookPayloads)
        }.value
    }

    /// `speechnotes-<date><scope-suffix>.jex` — the same naming BackupExport
    /// has always used, so a file keeps its meaning after it is sent.
    nonisolated static func fileName(scopeSuffix: String) -> String {
        let stamp = Date().formatted(.iso8601.year().month().day())
        return "speechnotes\(scopeSuffix)-\(stamp).jex"
    }
}
