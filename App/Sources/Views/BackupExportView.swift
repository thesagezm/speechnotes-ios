import SwiftUI
import UniformTypeIdentifiers
import SpeechLogic

/// One-tap export of the whole notes library to a Joplin-compatible .jex
/// file. Independent JEX reimplementation (see SpeechLogic/JexExport.swift).
struct BackupExportView: View {
    @State private var exportDocument: JexDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?

    private let notesCount: Int
    private let notebooksCount: Int

    init(notes: [Note], notebooks: [Notebook]) {
        self.notesCount = notes.count
        self.notebooksCount = notebooks.count
        self.notes = notes
        self.notebooks = notebooks
    }

    private let notes: [Note]
    private let notebooks: [Notebook]

    var body: some View {
        List {
            Section {
                Text("Export \(notesCount) notes\(notebooksCount > 0 ? " across \(notebooksCount) notebooks" : "") as a Joplin-compatible .jex file. Import it in Joplin desktop or mobile to move your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                .disabled(isExporting || notesCount == 0)
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
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

    private func defaultFilename() -> String {
        let stamp = Date().formatted(.iso8601.year().month().day())
        return "speechnotes-\(stamp).jex"
    }

    private func buildAndShare() {
        isExporting = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            let imageNoteTuples: [(UUID, String, String, UUID?, Date, Date)] = notes.map {
                ($0.id, $0.title, $0.text, $0.notebookId, $0.createdAt, $0.updatedAt)
            }
            let notebookTuples: [(UUID, String, Date)] = notebooks.map {
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
