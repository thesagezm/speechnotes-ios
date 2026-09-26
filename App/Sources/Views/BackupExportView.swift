import SwiftUI
import UniformTypeIdentifiers
import SpeechLogic

/// Export to Joplin (.jex) — the whole library, any selection of notebooks
/// (one or many), or the unfiled notes. Independent JEX reimplementation
/// (see SpeechLogic/JexExport.swift).
///
/// The original screen had one button that always exported everything. With
/// notebooks in the app that is rarely what someone wants: exporting
/// "Research" should not drag in every note that never got filed. v1.7:
/// the single-notebook picker became a multi-select (device request —
/// "allow me to select one or three notebooks") — Joplin's format carries
/// N folder entries per archive, and `JexExport.buildArchive` already took
/// arrays, so the pipe needed no change. Three scopes, and the summary line
/// states exactly what will be written before the share sheet opens.
struct BackupExportView: View {
    @State private var exportDocument: JexDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?
    /// Multi-select for the `.selected` scope.
    @State private var selectedNotebookIDs: Set<UUID> = []

    private let notes: [Note]
    private let notebooks: [Notebook]

    enum Scope: String, CaseIterable, Identifiable {
        case all
        case selected
        case unfiled

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "Everything"
            case .selected: return "Selected notebooks"
            case .unfiled: return "Unfiled notes"
            }
        }

        var detail: String {
            switch self {
            case .all:
                return "Every note and every notebook, with the folder structure Joplin needs to rebuild it."
            case .selected:
                return "The notes in the notebooks you tick, plus those notebooks so they land in the right place."
            case .unfiled:
                return "Every note that isn't in a notebook. No notebook folders are written."
            }
        }
    }

    @State private var scope: Scope = .all

    init(notes: [Note], notebooks: [Notebook]) {
        self.notes = notes
        self.notebooks = notebooks
    }

    // MARK: - Scoped selection

    private var scopedNotes: [Note] {
        switch scope {
        case .all: return notes
        case .selected:
            return notes.filter { note in
                guard let id = note.notebookId else { return false }
                return selectedNotebookIDs.contains(id)
            }
        case .unfiled:
            return notes.filter { $0.notebookId == nil }
        }
    }

    private var scopedNotebooks: [Notebook] {
        switch scope {
        case .all: return notebooks
        // Only the ticked containers go out — Joplin would otherwise create
        // empty folders for notebooks whose notes weren't exported.
        case .selected: return notebooks.filter { selectedNotebookIDs.contains($0.id) }
        case .unfiled: return []
        }
    }

    /// Never offer an archive with nothing in it.
    private var canExport: Bool { !scopedNotes.isEmpty }

    // MARK: - Body

    var body: some View {
        List {
            Section {
                Picker("Export", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("What to export")
            } footer: {
                Text(scope.detail)
            }

            if scope == .selected {
                Section {
                    ForEach(notebooks) { notebook in
                        notebookRow(notebook)
                    }
                    if notebooks.count > 1 {
                        Button(selectedNotebookIDs.count == notebooks.count ? "Deselect all" : "Select all") {
                            Haptics.tap()
                            if selectedNotebookIDs.count == notebooks.count {
                                selectedNotebookIDs = []
                            } else {
                                selectedNotebookIDs = Set(notebooks.map(\.id))
                            }
                        }
                    }
                } header: {
                    Text("Notebooks")
                } footer: {
                    Text("Pick any number — one, three, all of them. Each notebook becomes its own folder in Joplin.")
                }
            }

            Section {
                Button {
                    buildAndShare()
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Building archive…")
                        }
                    } else {
                        Label("Export to .jex", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || !canExport)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryLine)
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Export")
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .data,
            defaultFilename: defaultFilename()
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
    }

    private func notebookRow(_ notebook: Notebook) -> some View {
        let isSelected = selectedNotebookIDs.contains(notebook.id)
        let noteCount = notes.filter { $0.notebookId == notebook.id }.count
        return Button {
            Haptics.tap()
            if isSelected {
                selectedNotebookIDs.remove(notebook.id)
            } else {
                selectedNotebookIDs.insert(notebook.id)
            }
        } label: {
            HStack {
                Text(notebook.name)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(noteCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .accessibilityLabel("\(notebook.name), \(noteCount) notes, \(isSelected ? "selected" : "not selected")")
    }

    private var summaryLine: String {
        let noteCount = scopedNotes.count
        let notebookCount = scopedNotebooks.count
        var parts = ["\(noteCount) note\(noteCount == 1 ? "" : "s")"]
        if notebookCount > 0 {
            parts.append("\(notebookCount) notebook\(notebookCount == 1 ? "" : "s")")
        }
        let scopeName: String
        switch scope {
        case .all:
            scopeName = "your whole library"
        case .selected:
            let names = scopedNotebooks.map(\.name)
            if names.isEmpty {
                scopeName = "the ticked notebooks"
            } else if names.count <= 2 {
                scopeName = names.map { "\"\($0)\"" }.joined(separator: " and ")
            } else {
                scopeName = "\"\(names[0])\", \"\(names[1])\" and \(names.count - 2) more"
            }
        case .unfiled:
            scopeName = "unfiled notes"
        }
        return "Exports \(parts.joined(separator: " and ")) from \(scopeName)."
    }

    private func defaultFilename() -> String {
        let stamp = Date().formatted(.iso8601.year().month().day())
        let suffix: String
        switch scope {
        case .all: suffix = ""
        case .selected:
            let name = scopedNotebooks.first?.name ?? "notebooks"
            let slug = name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            suffix = slug.isEmpty ? "-notebooks" : "-" + slug
        case .unfiled: suffix = "-unfiled"
        }
        return "speechnotes\(suffix)-\(stamp).jex"
    }

    private func buildAndShare() {
        isExporting = true
        errorMessage = nil
        let notesSnapshot = scopedNotes
        let notebooksSnapshot = scopedNotebooks
        Task.detached(priority: .userInitiated) {
            let imageNoteTuples: [(UUID, String, String, UUID?, Date, Date)] = notesSnapshot.map {
                ($0.id, $0.title, $0.text, $0.notebookId, $0.createdAt, $0.updatedAt)
            }
            let notebookTuples: [(UUID, String, Date)] = notebooksSnapshot.map {
                ($0.id, $0.name, $0.createdAt)
            }
            let (notePayloads, notebookPayloads) = JexExport.payloads(
                notes: imageNoteTuples,
                notebooks: notebookTuples
            )
            let data = JexExport.buildArchive(notes: notePayloads, notebooks: notebookPayloads)
            await MainActor.run {
                isExporting = false
                exportDocument = JexDocument(data: data)
            }
        }
    }
}

/// Wraps the tar payload as a FileDocument for the share sheet.
private struct JexDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        .init(regularFileWithContents: data)
    }
}
