import SwiftUI
import UniformTypeIdentifiers
import SpeechLogic

/// Export to Joplin (.jex) — the whole library, any selection of notebooks
/// (one or many), or the unfiled notes. Independent JEX reimplementation
/// (see SpeechLogic/JexExport.swift), built through JexExporter so this
/// screen and BookDrop cannot drift.
///
/// The original screen had one button that always exported everything. With
/// notebooks in the app that is rarely what someone wants: exporting
/// "Research" should not drag in every note that never got filed. v1.7:
/// the single-notebook picker became a multi-select (device request —
/// "allow me to select one or three notebooks") — Joplin's format carries
/// N folder entries per archive, and `JexExport.buildArchive` already took
/// arrays, so the pipe needed no change. Three scopes, and the summary line
/// states exactly what will be written before the share sheet opens.
///
/// v1.7.4: three destinations for the built archive — the system share
/// sheet (Files, AirDrop, Mail…), Save to Files, and BookDrop to a nearby
/// device — plus "send straight to BookDrop" that builds the SAME archive
/// and opens the send sheet prefilled. A notebook exported this way lands
/// as a .jex on the other device and imports into Notes there.
struct BackupExportView: View {
    @EnvironmentObject private var notes: NotesStore
    @ObservedObject private var notebooks = NotebooksStore.shared
    @State private var exportDocument: JexDocument?
    /// The built .jex staged on disk for the system share sheet (Share, not
    /// Save — fileExporter is the save dialog, ShareSheet is the share one).
    @State private var sharingURL: URL?
    @State private var isExporting = false
    @State private var errorMessage: String?
    /// Multi-select for the `.selected` scope.
    @State private var selectedNotebookIDs: Set<UUID> = []

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

    // MARK: - Scoped selection

    private var scopedNotes: [Note] {
        switch scope {
        case .all: return notes.notes
        case .selected:
            return notes.notes.filter { note in
                guard let id = note.notebookId else { return false }
                return selectedNotebookIDs.contains(id)
            }
        case .unfiled:
            return notes.notes.filter { $0.notebookId == nil }
        }
    }

    private var scopedNotebooks: [Notebook] {
        switch scope {
        case .all: return NotebooksStore.sorted(notebooks.notebooks)
        // Only the ticked containers go out — Joplin would otherwise create
        // empty folders for notebooks whose notes weren't exported.
        case .selected: return NotebooksStore.sorted(notebooks.notebooks)
            .filter { selectedNotebookIDs.contains($0.id) }
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
                    ForEach(notebooks.notebooks) { notebook in
                        notebookRow(notebook)
                    }
                    if notebooks.notebooks.count > 1 {
                        Button(selectedNotebookIDs.count == notebooks.notebooks.count ? "Deselect all" : "Select all") {
                            Haptics.tap()
                            if selectedNotebookIDs.count == notebooks.notebooks.count {
                                selectedNotebookIDs = []
                            } else {
                                selectedNotebookIDs = Set(notebooks.notebooks.map(\.id))
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
                    build(for: .share)
                } label: {
                    if isExporting {
                        HStack {
                            ProgressView()
                            Text("Building archive…")
                        }
                    } else {
                        Label("Share archive", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || !canExport)

                Button {
                    build(for: .save)
                } label: {
                    Label("Save to Files…", systemImage: "folder")
                }
                .disabled(isExporting || !canExport)

                Button {
                    build(for: .bookDrop)
                } label: {
                    Label("Share with BookDrop", systemImage: "wifi")
                }
                .disabled(isExporting || !canExport)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summaryLine)
                    Text("Share opens the system share sheet (Files, AirDrop, Mail…); Save writes the .jex straight to a location you pick; BookDrop pushes it to a device on this Wi-Fi.")
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Export")
        .sheet(item: $sharingURL) { url in
            ShareSheet(items: [url])
        }
        .onDisappear {
            // The share sheet's staged copy is tmp — drop it when the screen
            // leaves, unless a sheet is holding it right now.
            sweepJexStaging(keeping: sharingURL)
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

    /// Removes this screen's leftover Share staging dirs (tmp/JexShare-*).
    /// `keeping` skips the dir behind an open share sheet's live URL.
    private func sweepJexStaging(keeping current: URL? = nil) {
        let tmp = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        let live = current?.deletingLastPathComponent()
        for url in contents where url.lastPathComponent.hasPrefix("JexShare-") && url != live {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func notebookRow(_ notebook: Notebook) -> some View {
        let isSelected = selectedNotebookIDs.contains(notebook.id)
        let noteCount = notes.notes.filter { $0.notebookId == notebook.id }.count
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
        JexExporter.fileName(scopeSuffix: scopeSuffix)
    }

    /// The filename slug for the current scope: "", "-<notebook-slug>", "-unfiled".
    private var scopeSuffix: String {
        switch scope {
        case .all: return ""
        case .selected:
            let name = scopedNotebooks.first?.name ?? "notebooks"
            let slug = name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            return slug.isEmpty ? "-notebooks" : "-" + slug
        case .unfiled: return "-unfiled"
        }
    }

    /// The three places a built archive can go — the argument that starts
    /// the one shared build.
    private enum Destination { case share, save, bookDrop }

    /// Builds the archive for the picked scope, then routes it to the
    /// destination that started the build. All three share one build so a
    /// notebook exported to BookDrop is byte-identical to the same
    /// notebook exported to Files.
    private func build(for destination: Destination) {
        guard !isExporting else { return }
        // Any staging dir from an earlier Share whose onDisappear never ran
        // (share sheet dismissed after the screen, system purge pending) —
        // sweep before making the next one.
        sweepJexStaging(keeping: sharingURL)
        isExporting = true
        errorMessage = nil
        let notesSnapshot = scopedNotes
        let notebooksSnapshot = scopedNotebooks
        let suffix = scopeSuffix
        Task {
            let data = await JexExporter.build(notes: notesSnapshot, notebooks: notebooksSnapshot)
            isExporting = false
            switch destination {
            case .save:
                // fileExporter's defaultFilename() names it; the document
                // only carries the bytes.
                exportDocument = JexDocument(data: data)
            case .share:
                // Stage the bytes under the pretty name and hand the URL to
                // the system share sheet — AirDrop/Mail/Files, whatever the
                // user picks.
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("JexShare-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let target = staging.appendingPathComponent(JexExporter.fileName(scopeSuffix: suffix))
                do {
                    try data.write(to: target, options: .atomic)
                    sharingURL = target
                } catch {
                    errorMessage = "Could not stage the archive for sharing."
                }
            case .bookDrop:
                // Hand the BYTES to the send sheet — no second build, no
                // staging round-trip. The request carries the archive as
                // an inline payload the sheet writes to its own tmp dir.
                NotificationCenter.default.post(
                    name: .bookDropSendRequest,
                    object: BookDropRequest(
                        payload: .jex,
                        jexScope: {
                            switch scope {
                            case .all: return .all
                            case .selected: return .selected
                            case .unfiled: return .unfiled
                            }
                        }(),
                        inlineJex: data,
                        inlineJexName: JexExporter.fileName(scopeSuffix: suffix)
                    )
                )
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
