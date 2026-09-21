import SwiftUI
import UniformTypeIdentifiers
import SpeechLogic

/// Export to Joplin (.jex) — the whole library, one notebook, or the
/// unfiled notes. Independent JEX reimplementation (see
/// SpeechLogic/JexExport.swift).
///
/// The original screen had one button that always exported everything. With
/// notebooks in the app that is rarely what someone wants: exporting
/// "Research" should not drag in every note that never got filed. Three
/// scopes, and the summary line states exactly what will be written before
/// the share sheet opens.
struct BackupExportView: View {
    @State private var exportDocument: JexDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?
    /// Which notebook is picked, when the scope is `.notebook`.
    @State private var selectedNotebookID: UUID?

    private let notes: [Note]
    private let notebooks: [Notebook]

    enum Scope: String, CaseIterable, Identifiable {
        case all
        case notebook
        case unfiled

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "Everything"
            case .notebook: return "One notebook"
            case .unfiled: return "Unfiled notes"
            }
        }

        var detail: String {
            switch self {
            case .all:
                return "Every note and every notebook, with the folder structure Joplin needs to rebuild it."
            case .notebook:
                return "The notes in one notebook, plus that notebook so they land in the right place."
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
        case .notebook:
            guard let selectedNotebookID else { return [] }
            return notes.filter { $0.notebookId == selectedNotebookID }
        case .unfiled:
            return notes.filter { $0.notebookId == nil }
        }
    }

    private var scopedNotebooks: [Notebook] {
        switch scope {
        case .all: return notebooks
        // A single notebook's export carries that one container and nothing
        // else — Joplin would otherwise create empty folders for notebooks
        // whose notes weren't exported.
        case .notebook:
            guard let selectedNotebookID else { return [] }
            return notebooks.filter { $0.id == selectedNotebookID }
        case .unfiled: return []
        }
    }

    /// Never offer an archive with nothing in it.
    private var canExport: Bool { !scopedNotes.isEmpty }

    private var selectedNotebook: Notebook? {
        notebooks.first { $0.id == selectedNotebookID }
    }

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

            if scope == .notebook {
                Section {
                    Picker("Notebook", selection: $selectedNotebookID) {
                        ForEach(notebooks) { notebook in
                            Text(notebook.name).tag(notebook.id as UUID?)
                        }
                    } label: {
                        Text("Notebook")
                    }
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
        .onAppear {
            // Default the picker to the first notebook, so "One notebook" is
            // never selected with nothing chosen.
            if selectedNotebookID == nil {
                selectedNotebookID = notebooks.first?.id
            }
        }
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

    private var summaryLine: String {
        let noteCount = scopedNotes.count
        let notebookCount = scopedNotebooks.count
        var parts = ["\(noteCount) note\(noteCount == 1 ? "" : "s")"]
        if notebookCount > 0 {
            parts.append("\(notebookCount) notebook\(notebookCount == 1 ? "" : "s")")
        }
        let scopeName: String
        switch scope {
        case .all: scopeName = "your whole library"
        case .notebook: scopeName = selectedNotebook.map { "\"\($0.name)\"" } ?? "the selected notebook"
        case .unfiled: scopeName = "unfiled notes"
        }
        return "Exports \(parts.joined(separator: " and ")) from \(scopeName)."
    }

    private func defaultFilename() -> String {
        let stamp = Date().formatted(.iso8601.year().month().day())
        let suffix: String
        switch scope {
        case .all: suffix = ""
        case .notebook:
            let name = selectedNotebook?.name ?? "notebook"
            let slug = name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            suffix = slug.isEmpty ? "-notebook" : "-" + slug
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
