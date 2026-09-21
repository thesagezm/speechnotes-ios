import SwiftUI

struct LogsView: View {
    @ObservedObject private var logs = Log.shared
    var embedded: Bool = false

    /// Observes the 1 Hz coalesced snapshot, not the raw entries array:
    /// playback logs 1-3 lines per second (chunk lines, bookmark writes,
    /// lock-screen publishes), and every line used to publish its own view
    /// refresh. `snapshotVersion` is the store's coalesced counter.
    @State private var renderedVersion: Int = -1

    var body: some View {
        Group {
            if logs.entries.isEmpty {
                ContentUnavailableView(
                    "No logs yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Actions in the app will show up here.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(logs.entries) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(entry.date) [\(entry.level)]")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // exportText recomputes a joined string over the whole
                // buffer; it must not rebuild per body evaluation, so the
                // toolbar item reads the CACHED copy refreshed at 1 Hz.
                ShareLink(item: cachedExportText)
            }
        }
        .onChange(of: logs.snapshotVersion) { _ in refreshCaches() }
        .onAppear { refreshCaches() }
    }

    @State private var cachedExportText: String = ""

    private func refreshCaches() {
        renderedVersion = logs.snapshotVersion
        cachedExportText = logs.exportText
    }
}
