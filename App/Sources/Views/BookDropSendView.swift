import SwiftUI
import SpeechLogic
import UniformTypeIdentifiers

/// The send half of BookDrop: pick a peer on this Wi-Fi and push books, JEX
/// archives or individual notes to it. Speaks LocalSend v2.2, so the
/// recipient can be a PC running LocalSend, another Speechnotes iPhone or
/// any BookDrop/LocalSend receiver-protocol app.
///
/// The items offered here are the SAME ones the system share sheet already
/// carries (a book's file, a .jex export, a note's text) — this is a second
/// route to them, not a second set of content.
struct BookDropSendView: View {
    @ObservedObject private var sender: LocalSendSender
    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var books: BooksStore
    @ObservedObject private var notebooks: NotebooksStore = .shared
    @Environment(\.dismiss) private var dismiss

    /// The user's choice: books, notes or a whole-library archive.
    private enum Payload: String, CaseIterable, Identifiable {
        case book
        case note
        case jex

        var id: String { rawValue }

        var label: String {
            switch self {
            case .book: return "A book"
            case .note: return "A note"
            case .jex: return "A .jex archive"
            }
        }

        var detail: String {
            switch self {
            case .book:
                    return "The original file as stored — an EPUB, PDF or audiobook lands with its real name."
            case .note:
                    return "The note's text as a markdown file, ready to drop into Joplin or any editor."
            case .jex:
                    return "Every note and notebook in one Joplin-compatible archive."
            }
        }
    }

    @State private var payload: Payload = .book
    @State private var selectedBookID: UUID?
    @State private var selectedNoteID: UUID?
    @State private var isBuilding = false
    @State private var buildError: String?
    /// Peers discovered by the last scan.
    @State private var peer: Peer?
    @State private var showPeerPicker = false

    @MainActor init() {
        _sender = ObservedObject(wrappedValue: LocalSendSender.shared)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What to send", selection: $payload) {
                        ForEach(Payload.allCases) { payload in
                            Text(payload.label).tag(payload)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Send")
                } footer: {
                    Text(payload.detail)
                }

                payloadSection

                Section {
                    peerRow
                } header: {
                    Text("Send to")
                } footer: {
                    Text("BookDrop finds Nearby devices on this Wi-Fi. The recipient must have Nearby BookDrop switched on.")
                }

                if let buildError {
                    Section {
                        Label(buildError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if let sendError = sender.lastError, sender.phase != .sending {
                    Section {
                        Label(sendError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if isBuilding {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if case .sending = sender.phase {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Sending…")
                                .font(.subheadline)
                            Spacer()
                            Button("Cancel", role: .cancel) { sender.cancelSend() }
                        }
                    }
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showPeerPicker) {
                peerPickerSheet
            }
            .onAppear {
                sender.reset()
                if selectedBookID == nil { selectedBookID = books.books.first?.id }
                if selectedNoteID == nil { selectedNoteID = notes.notes.first?.id }
                sender.scan()
            }
            // Whichever way the transfer ends, the staged copy of the payload
            // leaves with the sheet — a 700 MB book must not linger in tmp.
            .onChange(of: sender.phase) { newPhase in
                switch newPhase {
                case .completed, .failed:
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        cleanupStaging()
                    }
                default:
                    break
                }
            }
            .onDisappear {
                sender.stopScan()
                sender.cancelSend()
                cleanupStaging()
            }
        }
    }

    // MARK: - Payload pickers

    @ViewBuilder private var payloadSection: some View {
        Section {
            switch payload {
            case .book:
                if books.books.isEmpty {
                    Text("No books on the shelf yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Book", selection: $selectedBookID) {
                        ForEach(books.books) { book in
                            Text(book.title).tag(Optional(book.id))
                        }
                    }
                    .labelsHidden()
                }
            case .note:
                if notes.notes.isEmpty {
                    Text("No notes yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Note", selection: $selectedNoteID) {
                        ForEach(notes.notes) { note in
                            Text(note.title).tag(Optional(note.id))
                        }
                    }
                    .labelsHidden()
                }
            case .jex:
                LabeledContent("Contents", value: "\(notes.notes.count) notes, \(notebooks.notebooks.count) notebooks")
            }
        } header: {
            Text(payload.label)
        }
    }

    // MARK: - Peer

    @ViewBuilder private var peerRow: some View {
        if let peer {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.alias)
                        .font(.subheadline)
                    Text(peer.displayKind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change") { showPeerPicker = true }
                    .font(.subheadline)
            }
        } else {
            Button {
                sender.scan()
                showPeerPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Choose a device")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    // The picker sheet IS the send button: picking a peer starts the
    // transfer, so there is no second "confirm" step to mis-tap.
    private var peerPickerSheet: some View {
        NavigationStack {
            List {
                if case .scanning = sender.phase {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for devices on this Wi-Fi…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(sender.peers) { candidate in
                        Button {
                            peer = candidate
                            showPeerPicker = false
                            Task { await send(to: candidate) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "laptopcomputer")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.alias)
                                        .foregroundStyle(.primary)
                                    Text(candidate.displayKind)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Tapping a device sends straight away. Both devices must be on the same Wi-Fi, and the recipient's Nearby BookDrop must be on.")
                }
                Section {
                    Button {
                        sender.scan()
                    } label: {
                        Label("Scan again", systemImage: "arrow.clockwise")
                    }
                }
            }
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPeerPicker = false }
                }
            }
        }
    }

    // MARK: - Transfer

    private func send(to peer: Peer) async {
        guard let item = try? await buildItem() else {
            // buildItem reports its own failure through buildError.
            sender.cancelSend()
            return
        }
        isBuilding = false
        sender.send(files: [SendItem(
            url: item.url,
            fileName: item.fileName,
            fileType: item.fileType
        )], to: peer)
    }

    /// Resolves the picked payload to a file on disk. Books are already in
    /// Documents/; notes and archives are staged in tmp and removed after the
    /// transfer settles.
    private func buildItem() async throws -> (url: URL, fileName: String, fileType: String?) {
        buildError = nil
        isBuilding = true
        defer { isBuilding = false }

        switch payload {
        case .book:
            guard let id = selectedBookID, let book = books.books.first(where: { $0.id == id }) else {
                buildError = "Pick a book first."
                throw SendError.nothing
            }
            let url = BooksStore.resolveAudioOriginalURL(book)
            let extensionName = url.pathExtension.lowercased()
            let fileName = "\(sanitizedTitle(book.title)).\(extensionName)"
            // Documents/ files are the payload themselves — copy into tmp so
            // the transfer never depends on the library staying put.
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookDrop-send-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let target = staging.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                buildError = "Could not read that book's file."
                throw SendError.unreadable
            }
            return (target, fileName, contentType(for: extensionName))

        case .note:
            guard let id = selectedNoteID, let note = notes.notes.first(where: { $0.id == id }) else {
                buildError = "Pick a note first."
                throw SendError.nothing
            }
            let text = note.explicitTitle.map { "# \($0)\n\n\(note.text)" } ?? note.text
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookDrop-send-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let fileName = "\(sanitizedTitle(note.title)).md"
            let target = staging.appendingPathComponent(fileName)
            do {
                try Data(text.utf8).write(to: target, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                buildError = "Could not prepare the note."
                throw SendError.unreadable
            }
            return (target, fileName, "text/markdown")

        case .jex:
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookDrop-send-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let notesSnapshot = notes.notes
            let notebooksSnapshot = NotebooksStore.sorted(notebooks.notebooks)
            let noteTuples: [(UUID, String, String, UUID?, Date, Date)] = notesSnapshot.map {
                ($0.id, $0.title, $0.text, $0.notebookId, $0.createdAt, $0.updatedAt)
            }
            let notebookTuples: [(UUID, String, Date)] = notebooksSnapshot.map {
                ($0.id, $0.name, $0.createdAt)
            }
            let data: Data = await Task.detached(priority: .userInitiated) {
                let (notePayloads, notebookPayloads) = JexExport.payloads(
                    notes: noteTuples,
                    notebooks: notebookTuples
                )
                return JexExport.buildArchive(notes: notePayloads, notebooks: notebookPayloads)
            }.value
            let fileName = "speechnotes-\(Date().formatted(.iso8601.year().month().day())).jex"
            let target = staging.appendingPathComponent(fileName)
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                buildError = "Could not build the archive."
                throw SendError.unreadable
            }
            return (target, fileName, "application/joplin-archive")
        }
    }

    private enum SendError: Error {
        case nothing
        case unreadable
    }

    /// Removes the staging directory this view created for the payload. The
    /// sender holds the file open by URL while it streams, so the sweep waits
    /// until the phase settled (or the sheet closed).
    private func cleanupStaging() {
        let tmp = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("BookDrop-send-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func sanitizedTitle(_ title: String) -> String {
        let slug = title
            .replacingOccurrences(of: "/", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        return slug.isEmpty ? "Untitled" : String(slug.prefix(60))
    }

    private func contentType(for extensionName: String) -> String {
        switch extensionName {
        case "epub": return "application/epub+zip"
        case "pdf": return "application/pdf"
        case "m4b", "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "opus": return "audio/opus"
        case "ogg", "oga": return "audio/ogg"
        case "wav": return "audio/wav"
        case "jex": return "application/joplin-archive"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "odt": return "application/vnd.oasis.opendocument.text"
        case "html", "htm": return "text/html"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "rtf": return "application/rtf"
        case "fb2": return "application/x-fictionbook"
        default: return "application/octet-stream"
        }
    }
}
