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
        NavigationStack(path: $path) {
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
                // The completion is not guaranteed to arrive on the main
                // actor — every @State mutation below needs to.
                Task { @MainActor in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { importFile(at: url) }
                    case .failure(let error):
                        importErrorMessage = error.localizedDescription
                    }
                }
            }
            // Open-In files and speechnotes:// links (LiveContainer forwards
            // what it can; the Files picker and drag & drop always work).
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
        // Attached OUTSIDE the NavigationStack: two .sheet modifiers on the
        // same view node is the classic SwiftUI trap where one is ignored.
        .sheet(item: $sharingNote) { note in
            ShareSheet(items: [note.text])
        }
        // Mini-player jump-to-note: the global overlay posts a notification,
        // we switch tabs (SpeechnotesApp) and push the note here.
        .onReceive(NotificationCenter.default.publisher(for: .miniPlayerJumpToNote)) { note in
            guard let id = note.object as? UUID,
                  notes.notes.contains(where: { $0.id == id }) else { return }
            path.append(id)
        }
    }

    // MARK: - List

    private var notesList: some View {
        List {
            ForEach(sectionedNotes, id: \.title) { section in
                Section {
                    ForEach(section.notes) { note in
                        NavigationLink(value: note.id) {
                            noteRow(note)
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

    private func noteRow(_ note: Note) -> some View {
        // Computed once — preview() walks the whole body, twice per row per
        // render was measurable on device.
        let previewText = preview(of: note)
        return VStack(alignment: .leading, spacing: 4) {
            Text(note.title)
                .font(.headline)
            if !previewText.isEmpty {
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                Text("·").foregroundStyle(.tertiary)
                Text("\(note.wordCount) words")
                if let minutes = note.estimatedListenMinutes {
                    Text("·").foregroundStyle(.tertiary)
                    Text("~\(minutes) min listen")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// First ~120 characters of the body (everything after the title line),
    /// whitespace-normalized. The scan is capped: rows re-render on every
    /// player publish, and whole-text walks were measurable with long notes.
    private func preview(of note: Note) -> String {
        let source = note.text.count > 800 ? String(note.text.prefix(800)) : note.text
        let body = source
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(body.prefix(120))
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

extension Notification.Name {
    /// Posted by the mini-player when the user taps the bar body.
    /// `object` is the speaking note's `UUID`.
    static let miniPlayerJumpToNote = Notification.Name("MiniPlayerBar.jumpToNote")
}
