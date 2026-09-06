import SwiftUI

struct NotesListView: View {
    @EnvironmentObject private var notes: NotesStore
    @EnvironmentObject private var player: SpeechPlayer
    @ObservedObject private var notebooks = NotebooksStore.shared
    @State private var path: [UUID] = []
    @State private var showingImporter = false
    @State private var importErrorMessage: String?
    @State private var searchText = ""
    @State private var sort: SortOrder = SortOrder.stored
    /// Note whose text the share sheet is presenting (leading swipe → Share).
    @State private var sharingNote: Note?
    @State private var showingRecycleBin = false
    @State private var showingNotebookManager = false

    /// Which notebook the list is scoped to. Persisted as a string
    /// ("all" / "unfiled" / "nb-<uuid>") so relaunching restores the view.
    private enum Scope: Hashable {
        case all, unfiled, notebook(UUID)
    }

    @AppStorage("activeNotebookScope") private var activeScopeRaw = "all"

    private var scope: Scope {
        if activeScopeRaw == "unfiled" { return .unfiled }
        if activeScopeRaw.hasPrefix("nb-"),
           let id = UUID(uuidString: String(activeScopeRaw.dropFirst(3))) {
            return .notebook(id)
        }
        return .all
    }

    private func select(_ newScope: Scope) {
        switch newScope {
        case .all: activeScopeRaw = "all"
        case .unfiled: activeScopeRaw = "unfiled"
        case .notebook(let id): activeScopeRaw = "nb-\(id.uuidString)"
        }
    }

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
        // Notebook scope first (v1.4 grouping).
        switch scope {
        case .all: break
        case .unfiled: list = list.filter { $0.notebookId == nil }
        case .notebook(let id): list = list.filter { $0.notebookId == id }
        }
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
    /// a single anonymous section otherwise. Pinned notes (v1.4) float to
    /// their own "Pinned" section on top.
    private var sectionedNotes: [(title: String?, notes: [Note])] {
        var sections: [(title: String?, notes: [Note])] = []
        let pinned = visibleNotes.filter { $0.isPinned }
        let rest = visibleNotes.filter { !$0.isPinned }
        if !pinned.isEmpty { sections.append(("Pinned", pinned)) }
        if sort == .edited {
            var order: [String] = []
            var groups: [String: [Note]] = [:]
            for note in rest {
                let key = era(for: note.updatedAt)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(note)
            }
            sections.append(contentsOf: order.map { ($0, groups[$0]!) })
        } else if !rest.isEmpty {
            sections.append((nil, rest))
        }
        return sections
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if notes.notes.isEmpty {
                    emptyState
                } else if visibleNotes.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if visibleNotes.isEmpty {
                    scopeEmptyState
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
            .onChange(of: sort) { newValue in
                newValue.persist()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    sortAndImportMenu
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let note = notes.createNote(notebookId: scopeNotebookId)
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
            .sheet(isPresented: $showingNotebookManager) {
                NotebookListView(notebooks: notebooks, notes: notes)
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

    /// Notebook chips (Joplin-style scoping): All / notebooks / Unfiled,
    /// plus the manage entry. Rendered as the list's first section.
    private var notebookChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                scopeChip(title: "All notes", count: notes.notes.count, isActive: scope == .all) {
                    select(.all)
                }
                ForEach(notebooks.notebooks) { notebook in
                    scopeChip(
                        title: notebook.name,
                        count: notes.notes(inNotebook: notebook.id).count,
                        isActive: scope == .notebook(notebook.id)
                    ) {
                        select(.notebook(notebook.id))
                    }
                }
                scopeChip(
                    title: "Unfiled",
                    count: notes.notes(inNotebook: nil).count,
                    isActive: scope == .unfiled
                ) {
                    select(.unfiled)
                }
                Button {
                    Haptics.tap()
                    showingNotebookManager = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                .accessibilityLabel("Manage notebooks")
            }
            .padding(.horizontal, 4)
        }
    }

    private func scopeChip(title: String, count: Int, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isActive ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var notesList: some View {
        List {
            Section {
                notebookChipRow
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 2, trailing: 12))
                    .listRowBackground(Color.clear)
            }

            ForEach(sectionedNotes, id: \.title) { section in
                Section {
                    ForEach(section.notes) { note in
                        NavigationLink(value: note.id) {
                            NoteRowView(note: note, preview: notes.preview(for: note))
                        }
                        .contextMenu {
                            Button {
                                notes.setPinned(!note.isPinned, noteId: note.id)
                            } label: {
                                Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
                            }
                            Button {
                                notes.setFavorite(!note.isFavorite, noteId: note.id)
                            } label: {
                                Label(note.isFavorite ? "Unfavorite" : "Favorite", systemImage: note.isFavorite ? "star.slash" : "star")
                            }
                            Menu {
                                Button("Unfiled") {
                                    notes.move(noteId: note.id, to: nil)
                                }
                                ForEach(notebooks.notebooks) { notebook in
                                    Button(notebook.name) {
                                        notes.move(noteId: note.id, to: notebook.id)
                                    }
                                }
                            } label: {
                                Label("Move to notebook", systemImage: "folder")
                            }
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
                                notes.setPinned(!note.isPinned, noteId: note.id)
                            } label: {
                                Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
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

    private func era(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: Date()).day ?? .max
        if days < 7 { return "Previous 7 days" }
        return "Older"
    }

    /// Notebook id for the active scope — nil for All/Unfiled.
    private var scopeNotebookId: UUID? {
        if case .notebook(let id) = scope { return id }
        return nil
    }

    private var scopeEmptyState: some View {
        ContentUnavailableView {
            Label(
                scope == .unfiled ? "No unfiled notes" : "No notes in this notebook",
                systemImage: "tray"
            )
        } description: {
            Text("New notes created here land in this scope.")
        } actions: {
            Button {
                let note = notes.createNote(notebookId: scopeNotebookId)
                path.append(note.id)
            } label: {
                Label("New note", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No notes yet", systemImage: "waveform")
        } description: {
            Text("Write something and hear it read aloud — fully offline.")
        } actions: {
            HStack(spacing: 12) {
                Button {
                    let note = notes.createNote(notebookId: scopeNotebookId)
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
        let note = notes.createNote(notebookId: scopeNotebookId)
        var updated = note
        updated.text = text
        notes.update(updated)
        path.append(note.id)
    }
}
