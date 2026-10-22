import Foundation

/// What a screen wants BookDrop to send, posted as a notification so any
/// surface (BackupExport, Storage, a note's swipe, a book's context menu)
/// can hand its selection to the SAME send sheet without a shared
/// navigation path. The sheet prefills exactly what was asked for.
struct BookDropRequest: Identifiable {
    /// Stable per-request id so the app-level `.sheet(item:)` presents once.
    let id = UUID()

    enum Payload: String {
        case book
        case note
        case export
        case jex
    }

    var payload: Payload = .jex
    var bookIDs: [UUID] = []
    var noteIDs: [UUID] = []
    var exportURLs: [URL] = []
    /// Only meaningful for `.jex`: every note/notebook, the notebook
    /// multi-select, or just the unfiled.
    var jexScope: JexScope = .all
    /// A prebuilt .jex (BackupExport builds it once and hands the bytes
    /// over) — when set, the sheet stages THIS archive instead of rebuilding.
    var inlineJex: Data?
    var inlineJexName: String?

    enum JexScope: String {
        case all, selected, unfiled
    }
}

extension Notification.Name {
    /// object = a BookDropRequest. The sheet is app-level (SpeechnotesApp);
    /// this is how any screen opens it pre-filled.
    static let bookDropSendRequest = Notification.Name("BookDrop.sendRequest")
}
