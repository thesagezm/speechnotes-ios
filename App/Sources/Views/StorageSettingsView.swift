import SwiftUI

struct StorageSettingsView: View {
    @State private var showingClearConfirm = false

    var body: some View {
        Form {
            Section("Exported Audio") {
                HStack {
                    Text("Total size")
                    Spacer()
                    Text(ExportsStore.totalFormattedSize)
                        .foregroundStyle(.secondary)
                }
                Button("Clear temporary files") {
                    showingClearConfirm = true
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Storage")
        .alert("Clear temporary files?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                let bytes = ExportsStore.clearTemporaryFiles()
                print("Freed \(bytes) bytes")
            }
        } message: {
            Text("Remove cached WAVs generated inside the app. Exported files in Documents remain.")
        }
    }
}
