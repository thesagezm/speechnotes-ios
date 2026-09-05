import SwiftUI

struct NotesListView: View {
    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @State private var path: [UUID] = []
    @State private var showingImporter = false
    @State private var importErrorMessage: String?
    @State private var searchText = ""
    @State private var sort: SortOrder = SortOrder.stored
    /// Note whose text the share sheet is presenting (leading swipe → Share).
    @State private var sharingNote: Note?
    @State private var showingRecycleBin = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case edited, created, title

        var id: String { rawValue }

        var label: String {
            switch self {
            case .edited: return "Last edited"
            case .created: return "Date created"
            case .title: return "Title"
            }
        }

        var icon: String {
            switch self {
            case .edited: return "pencil.and.list.clipboard"
            case .created: return "calendar"
            case .title: return "textformat.abc"
            }
        }

        /// Persisted preference, defaulting to last-edited.
        static var stored: SortOrder {
            UserDefaults.standard.string(forKey: "notesSortOrder").flatMap(SortOrder.init(rawValue:)) ?? .edited
        }

        func persist() {
            UserDefaults.standard.set(rawValue, forKey: "notesSortOrder")
        }
    }

    private var visibleNotes: [Note] {
        var list = notes.notes
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(needle) || $0.text.lowercased().contains(needle)
            }
        }
        switch sort {
        case .edited: list.sort { $0.updatedAt > $1.updatedAt }
        case .created: list.sort { $0.createdAt > $1.createdAt }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return list
    }

    /// Date-era sections (Today / Yesterday / …) when sorted by edit date —
    /// a single anonymous section otherwise.
    private var sectionedNotes: [(title: String?, notes: [Note])] {
        guard sort == .edited else { return [(nil, visibleNotes)] }
        var order: [String] = []
        var groups: [String: [Note]] = [:]
        for note in visibleNotes {
            let key = era(for: note.updatedAt)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(note)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var body: some View {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launch-diagnostics.log")
        let msg = "\(ISO8601DateFormatter().string(from: Date())): NotesListView.body\n"
        try? msg.write(to: url, atomically: true, encoding: .utf8)

        return NavigationStack(path: $path) {
            Group {
                if notes.notes.isEmpty {
                    emptyState
                } else if visibleNotes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    notesList
                }
            }
            .navigationTitle("Speechnotes")
            .navigationDestination(for: UUID.self) { id in
                NoteEditorView(noteId: id)
            }
            .navigationDestination(isPresented: $showingRecycleBin) {
                RecycleBinView()
            }
            .searchable(text: $searchText, prompt: "Search notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    sortAndImportMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let note = notes.createNote()
                        path.append(note.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New note")
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: ImportService.acceptedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { importFile(at: url) }
                    case .failure(let error):
                        importErrorMessage = error.localizedDescription
                    }
                }
            }
            .onOpenURL { url in
                handleOpenURL(url)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                importFile(at: url)
                return true
            }
            .dropDestination(for: String.self) { strings, _ in
                guard let text = strings.first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty else { return false }
                addNote(text: text)
                return true
            }
            .sheet(isPresented: shareSheetBinding) {
                if let url = player.shareURL {
                    ShareSheet(items: [url])
                }
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { importErrorMessage != nil },
                    set: { if !$0 { importErrorMessage = nil } }
                )
            ) {
                Button("OK") { importErrorMessage = nil }
            } message: {
                Text(importErrorMessage ?? "")
            }
        }
        .sheet(item: $sharingNote) { note in
            ShareSheet(items: [note.text])
        }
        .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToNote)) { _ in
            jumpToPlayingNote()
        }
    }

    // MARK: - List

    private var notesList: some View {
        List {
            ForEach(sectionedNotes, id: \.title) { section in
                Section {
                    ForEach(section.notes) { note in
                        NavigationLink(value: note.id) {
                            NoteRowView(note: note, preview: notes.preview(for: note))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                notes.delete(noteId: note.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                sharingNote = note
                            } label: {
                                Label("Share", systemImage: "doc.on.doc")
                            }
                            .tint(.indigo)
                            Button {
                                exportNote(note)
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                    // Offsets index this section's slice, not the store —
                    // resolve to ids before deleting.
                    .onDelete { offsets in
                        for index in offsets {
                            notes.delete(noteId: section.notes[index].id)
                        }
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }
    }

    /// One row in the notes list — legacy path kept for compatibility. The
    /// list now uses NoteRowView directly so this is unused. Remove at leisure.
    private func noteRow(_ note: Note) -> some View {
        NoteRowView(note: note, preview: notes.preview(for: note))
    }

    private func era(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: Date()).day ?? .max
        if days < 7 { return "Previous 7 days" }
        return "Older"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No notes yet", systemImage: "waveform")
        } description: {
            Text("Write something and hear it read aloud — fully offline.")
        } actions: {
            HStack(spacing: 12) {
                Button {
                    let note = notes.createNote()
                    path.append(note.id)
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var sortAndImportMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(SortOrder.allCases) { order in
                    Label(order.label, systemImage: order.icon).tag(order)
                }
            }
            Divider()
 Button {
 showingImporter = true
 } label: {
 Label("Import from Files…", systemImage: "folder")
 }
 Divider()
 Button {
 showingRecycleBin = true
 } label: {
 Label(
 "Recently Deleted\(!notes.deletedNotes.isEmpty ? " (\(notes.deletedNotes.count))" : "")",
 systemImage: "trash"
 )
 }
            // hasStrings is a cheap content-free check — reading .string here
            // would hit the (possibly remote) pasteboard on every render and
            // can trigger iOS paste prompts. Content is read on tap instead.
            if UIPasteboard.general.hasStrings {
                Button {
                    importFromClipboard()
                } label: {
                    Label("New note from clipboard", systemImage: "doc.on.clipboard")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Actions

    private func importFromClipboard() {
        guard let text = ImportService.clipboardText() else { return }
        addNote(text: text)
    }

    private func exportNote(_ note: Note) {
        Haptics.tap()
        player.export(note.text)
    }

    private func jumpToPlayingNote() {
        guard let id = player.nowPlayingNoteId,
              notes.notes.contains(where: { $0.id == id }) else { return }
        if path != [id] {        // re-render once; keep the root stable
            path = [id]
        }
    }

    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { player.shareURL != nil },
            set: { if !$0 { player.shareURL = nil } }
        )
    }

    // MARK: - Import

    private func importFile(at url: URL) {
        guard ImportService.canImport(url) else {
            importErrorMessage = "Unsupported file type: \(url.lastPathComponent)"
            return
        }
        Task.detached(priority: .userInitiated) {
            let imported = ImportService.importText(from: url)
            await MainActor.run {
                guard let imported else {
                    Haptics.warning()
                    importErrorMessage = "Could not extract text from \(url.lastPathComponent)."
                    return
                }
                Haptics.success()
                addNote(text: imported.text)
            }
        }
    }

    private func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            importFile(at: url)
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "speechnotes" else { return }
        guard let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Log.shared.error("NotesList: speechnotes:// URL without usable text")
            return
        }
        addNote(text: text)
    }

    /// Imported text lands verbatim; the note's title derives from its first
    /// line like every other note.
    private func addNote(text: String) {
        let note = notes.createNote()
        var updated = note
        updated.text = text
        notes.update(updated)
        path.append(note.id)
    }
}
