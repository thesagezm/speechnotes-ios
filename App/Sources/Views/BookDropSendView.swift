import SwiftUI
import SpeechLogic
import UniformTypeIdentifiers

/// The send half of BookDrop: pick a peer on this Wi-Fi and push books
/// (incl. audiobooks), notes, exported audio or JEX archives to it — any
/// mix, several at once. Speaks LocalSend v2.2, so the recipient can be a
/// PC running LocalSend, another Speechnotes iPhone or any
/// BookDrop/LocalSend receiver-protocol app.
///
/// The items offered here are the SAME ones the system share sheet already
/// carries — this is a second route to them, not a second set of content.
/// Screens don't host their own copy of this sheet: they post a
/// BookDropRequest and the app-level sheet opens prefilled (Storage's
/// export rows, BackupExport's scope picker, a note's swipe, a book's
/// context menu — all land here with their selection already ticked).
struct BookDropSendView: View {
    @ObservedObject private var sender: LocalSendSender
    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var books: BooksStore
    @ObservedObject private var notebooks: NotebooksStore = .shared
    @ObservedObject private var exports = ExportsStore()
    @Environment(\.dismiss) private var dismiss

    /// The user's choice: books, notes, exported audio or a whole-library
    /// archive. Any of them can carry a multi-selection.
    private enum Payload: String, CaseIterable, Identifiable {
        case book
        case note
        case export
        case jex

        var id: String { rawValue }

        var label: String {
            switch self {
            case .book: return "Books & audiobooks"
            case .note: return "Notes"
            case .export: return "Exported audio"
            case .jex: return "A .jex archive"
            }
        }

        var detail: String {
            switch self {
            case .book:
                return "The original file as stored — an EPUB, PDF or audiobook lands with its real name. Tick as many as you like."
            case .note:
                return "Each note becomes its own markdown file, ready to drop into Joplin or any editor. Tick as many as you like."
            case .export:
                return "WAV recordings from Documents/Exports — the same files Storage lists. Tick as many as you like."
            case .jex:
                return "Every note and notebook in one Joplin-compatible archive — or the exact archive you just built on the Export screen."
            }
        }
    }

    @State private var payload: Payload = .book
    @State private var selectedBookIDs: Set<UUID> = []
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var selectedExportURLs: Set<URL> = []
    /// Prebuilt archive handed over by BackupExport — staged verbatim.
    @State private var inlineJex: Data?
    @State private var inlineJexName: String?
    /// Scope note shown when the .jex was prefilled from the Export screen.
    @State private var jexScopeNote: String?
    @State private var isBuilding = false
    @State private var buildError: String?
    /// Peers discovered by the last scan.
    @State private var peer: Peer?
    @State private var showPeerPicker = false
    /// The access code the DESTINATION demands. Deliberately a different
    /// defaults key from the receiver's own `bookDropPin` (BookDropView):
    /// this device can both REQUIRE a code from others and SEND to a peer
    /// whose code is different — one key would cross-contaminate them.
    @AppStorage("bookDropSendPin") private var pinText = ""

    /// Prefill from a posted BookDropRequest (nil when opened bare from
    /// BookDropView's "Send to a device").
    @MainActor
    init(initial request: BookDropRequest? = nil) {
        _sender = ObservedObject(wrappedValue: LocalSendSender.shared)
        if let request {
            _payload = State(initialValue: {
                switch request.payload {
                case .book: return .book
                case .note: return .note
                case .export: return .export
                case .jex: return .jex
                }
            }())
            _selectedBookIDs = State(initialValue: Set(request.bookIDs))
            _selectedNoteIDs = State(initialValue: Set(request.noteIDs))
            _selectedExportURLs = State(initialValue: Set(request.exportURLs))
            _inlineJex = State(initialValue: request.inlineJex)
            _inlineJexName = State(initialValue: request.inlineJexName)
            if request.inlineJex != nil {
                switch request.jexScope {
                case .all: _jexScopeNote = State(initialValue: "The archive you built — everything.")
                case .selected: _jexScopeNote = State(initialValue: "The archive you built — your selected notebooks.")
                case .unfiled: _jexScopeNote = State(initialValue: "The archive you built — unfiled notes.")
                }
            }
        }
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
                    accessCodeRow
                } header: {
                    Text("Send to")
                } footer: {
                    Text("BookDrop finds Nearby devices on this Wi-Fi. The recipient must have Nearby BookDrop switched on; if it asks for an access code, type the same code here.")
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
                if !sender.peers.isEmpty, peer == nil { showPeerPicker = true }
                if peer == nil { sender.scan() }
                // A prefilled note (context menu on a note far down the
                // list) must be VISIBLE in the picker, not just counted —
                // expand past the preview window when the selection
                // isn't inside it.
                if !selectedNoteIDs.isEmpty,
                   !selectedNoteIDs.isSubset(of: Set(notes.notes.prefix(selectableNotePreviewLimit).map(\.id))) {
                    showingAllNotes = true
                }
            }
            // Whichever way the transfer ends, the staged copies of the
            // payload leave with the sheet — a 700 MB book must not linger
            // in tmp.
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
        switch payload {
        case .book:
            Section {
                if books.books.isEmpty {
                    Text("No books on the shelf yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(books.books) { book in
                        selectableRow(
                            title: book.title,
                            subtitle: book.authorOrFormat,
                            isSelected: selectedBookIDs.contains(book.id)
                        ) {
                            Haptics.tap()
                            toggle(&selectedBookIDs, book.id)
                        }
                    }
                }
            } header: {
                Text(selectionHeader("Books", selectedBookIDs.count))
            } footer: {
                if !books.books.isEmpty {
                    Text("Audiobooks send their original M4B/MP3/Opus file; EPUBs and PDFs send theirs. The reading position stays on this device.")
                }
            }
        case .note:
            Section {
                if notes.notes.isEmpty {
                    Text("No notes yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleNotes) { note in
                        selectableRow(
                            title: note.title,
                            subtitle: nil,
                            isSelected: selectedNoteIDs.contains(note.id)
                        ) {
                            Haptics.tap()
                            toggle(&selectedNoteIDs, note.id)
                        }
                    }
                    if notes.notes.count > selectableNotePreviewLimit {
                        Button {
                            Haptics.tap()
                            showingAllNotes.toggle()
                        } label: {
                            Label(
                                showingAllNotes ? "Show fewer" : "See all \(notes.notes.count) notes",
                                systemImage: showingAllNotes ? "chevron.up" : "chevron.down"
                            )
                            .font(.subheadline.weight(.medium))
                        }
                    }
                }
            } header: {
                Text(selectionHeader("Notes", selectedNoteIDs.count))
            } footer: {
                Text("Each ticked note goes out as its own markdown file.")
            }
        case .export:
            Section {
                if exports.exports.isEmpty {
                    Text("No exported audio yet — use 'Export WAV' in a note's … menu.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(exports.exports) { item in
                        selectableRow(
                            title: item.name,
                            subtitle: item.sizeLabel,
                            isSelected: selectedExportURLs.contains(item.url)
                        ) {
                            Haptics.tap()
                            toggle(&selectedExportURLs, item.url)
                        }
                    }
                }
            } header: {
                Text(selectionHeader("Exported audio", selectedExportURLs.count))
            } footer: {
                Text("The WAV files Storage lists. The same files the system share sheet offers.")
            }
        case .jex:
            Section {
                if let inlineJex, let inlineJexName {
                    LabeledContent("Contents", value: inlineJexName)
                    if let jexScopeNote {
                        Text(jexScopeNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(
                        "Contents",
                        value: "\(notes.notes.count) notes, \(notebooks.notebooks.count) notebooks"
                    )
                }
            } header: {
                Text("A .jex archive")
            } footer: {
                Text("The receiving device imports it into Notes (Settings → Backup → Import from Joplin) — or into Joplin itself on a computer.")
            }
        }
    }

    private var selectableNotePreviewLimit: Int { 40 }
    @State private var showingAllNotes = false
    private var visibleNotes: [Note] {
        showingAllNotes ? notes.notes : Array(notes.notes.prefix(selectableNotePreviewLimit))
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func selectionHeader(_ kind: String, _ count: Int) -> String {
        count == 0 ? kind : "\(kind) — \(count) selected"
    }

    private func selectableRow(title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .accessibilityLabel("\(title), \(isSelected ? "selected" : "not selected")")
    }

    // MARK: - Peer + access code

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

    /// Only meaningful when the RECEIVING device has an access code set
    /// (BookDrop → Receive → Access code). Empty = open network send.
    private var accessCodeRow: some View {
        SecureField("Access code (leave blank if the receiver has none)", text: $pinText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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
        guard let items = try? await buildItems() else {
            // buildItems reports its own failure through buildError.
            sender.cancelSend()
            return
        }
        isBuilding = false
        sender.send(files: items, to: peer, pin: pinText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Resolves the picked payload to files on disk. Books and archives are
    /// staged in tmp (so the transfer never depends on the library staying
    /// put); note markdown files are written fresh; export WAVs stream from
    /// Documents/Exports as-is.
    private func buildItems() async throws -> [SendItem] {
        buildError = nil
        isBuilding = true
        defer { isBuilding = false }

        switch payload {
        case .book:
            let chosen = books.books.filter { selectedBookIDs.contains($0.id) }
            guard !chosen.isEmpty else {
                buildError = "Tick at least one book."
                throw SendError.nothing
            }
            return try chosen.map { book in
                let source: URL = book.format == .audio
                    ? BooksStore.resolveAudioOriginalURL(book: book)
                    : BooksStore.originalFileURL(book)
                let extensionName = source.pathExtension.isEmpty
                    ? book.format.rawValue
                    : source.pathExtension.lowercased()
                let fileName = "\(sanitizedTitle(book.title)).\(extensionName)"
                let target = try stage(url: source, fileName: fileName, reason: "Could not read that book's file.")
                return SendItem(url: target, fileName: fileName, fileType: contentType(for: extensionName))
            }

        case .note:
            let chosen = notes.notes.filter { selectedNoteIDs.contains($0.id) }
            guard !chosen.isEmpty else {
                buildError = "Tick at least one note."
                throw SendError.nothing
            }
            return try chosen.map { note in
                let text = note.explicitTitle.map { "# \($0)\n\n\(note.text)" } ?? note.text
                let fileName = "\(sanitizedTitle(note.title)).md"
                let staging = stagingDirectory()
                let target = staging.appendingPathComponent(fileName)
                do {
                    try Data(text.utf8).write(to: target, options: .atomic)
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    buildError = "Could not prepare a note."
                    throw SendError.unreadable
                }
                return SendItem(url: target, fileName: fileName, fileType: "text/markdown")
            }

        case .export:
            let chosen = exports.exports.filter { selectedExportURLs.contains($0.url) }
            guard !chosen.isEmpty else {
                buildError = "Tick at least one export."
                throw SendError.nothing
            }
            // Documents/Exports is ours: no staging copy needed, the sender
            // streams straight from the file it will keep playing from.
            return chosen.map { item in
                SendItem(url: item.url, fileName: item.url.lastPathComponent, fileType: "audio/wav")
            }

        case .jex:
            let data: Data
            let fileName: String
            if let inlineJex {
                // BackupExport already built this archive — send the bytes
                // verbatim rather than rebuilding a second copy.
                data = inlineJex
                fileName = inlineJexName ?? JexExporter.fileName(scopeSuffix: "")
            } else {
                let notesSnapshot = notes.notes
                let notebooksSnapshot = NotebooksStore.sorted(notebooks.notebooks)
                data = await JexExporter.build(notes: notesSnapshot, notebooks: notebooksSnapshot)
                fileName = JexExporter.fileName(scopeSuffix: "")
            }
            let staging = stagingDirectory()
            let target = staging.appendingPathComponent(fileName)
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                buildError = "Could not build the archive."
                throw SendError.unreadable
            }
            return [SendItem(url: target, fileName: fileName, fileType: "application/joplin-archive")]
        }
    }

    private func stagingDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookDrop-send-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a library file into this view's staging dir so the transfer
    /// doesn't race a re-import/delete of the original.
    private func stage(url: URL, fileName: String, reason: String) throws -> URL {
        let staging = stagingDirectory()
        let target = staging.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            buildError = reason
            throw SendError.unreadable
        }
        return target
    }

    private enum SendError: Error {
        case nothing
        case unreadable
    }

    /// Removes the staging directories this view created for the payloads.
    /// The sender holds the files open by URL while it streams, so the sweep
    /// waits until the phase settled (or the sheet closed).
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
