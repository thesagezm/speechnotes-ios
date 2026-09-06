import SwiftUI

/// Create / rename / delete notebooks (Joplin-style, flat). Deleting a
/// notebook moves its notes back to Unfiled — never deletes the notes.
struct NotebookListView: View {
    @ObservedObject var notebooks: NotebooksStore
    @ObservedObject var notes: NotesStore
    @Environment(\.dismiss) private var dismiss

    @State private var newNotebookName = ""
    @State private var renamingNotebook: Notebook?
    @State private var renameDraft = ""
    @State private var deletingNotebook: Notebook?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New notebook name", text: $newNotebookName)
                            .onSubmit(addNotebook)
                        Button {
                            addNotebook()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newNotebookName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Add notebook")
                    }
                } footer: {
                    Text("Notebooks group your notes. A note lives in exactly one notebook; deleting a notebook keeps its notes (they become Unfiled).")
                }

                Section("Notebooks") {
                    if notebooks.notebooks.isEmpty {
                        Text("No notebooks yet — add one above.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(notebooks.notebooks) { notebook in
                            Button {
                                renameDraft = notebook.name
                                renamingNotebook = notebook
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(Color.accentColor)
                                    Text(notebook.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(notes.notes(inNotebook: notebook.id).count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                            // Make deletion discoverable: a visible trash
                            // glyph, a swipe action and the context menu all
                            // route through the same confirmation.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    deletingNotebook = notebook
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .contextMenu {
                                Button {
                                    renameDraft = notebook.name
                                    renamingNotebook = notebook
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deletingNotebook = notebook
                                } label: {
                                    Label("Delete notebook", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                let notebook = notebooks.notebooks[index]
                                deletingNotebook = notebook
                            }
                        }
                    }
                }
            }
            .navigationTitle("Notebooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete \(deletingNotebook?.name ?? "notebook")?",
                isPresented: Binding(
                    get: { deletingNotebook != nil },
                    set: { if !$0 { deletingNotebook = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete notebook", role: .destructive) {
                    if let notebook = deletingNotebook {
                        notes.clearNotebook(notebook.id)
                        notebooks.delete(notebook)
                    }
                    deletingNotebook = nil
                }
            } message: {
                Text("Its notes are kept and become Unfiled.")
            }
            .alert("Rename notebook", isPresented: Binding(
                get: { renamingNotebook != nil },
                set: { if !$0 { renamingNotebook = nil } }
            )) {
                TextField("Name", text: $renameDraft)
                Button("Save") {
                    if let notebook = renamingNotebook {
                        notebooks.rename(notebook, to: renameDraft)
                    }
                    renamingNotebook = nil
                }
                Button("Cancel", role: .cancel) { renamingNotebook = nil }
            }
        }
    }

    private func addNotebook() {
        if notebooks.create(name: newNotebookName) != nil {
            Haptics.success()
            newNotebookName = ""
        } else {
            Haptics.warning()
        }
    }
}
