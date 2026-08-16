import SwiftUI

struct LogsView: View {
    @ObservedObject private var logs = Log.shared

    var body: some View {
        NavigationStack {
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
                                    Text(
                                        "\(entry.date, format: .dateTime.hour().minute().second()) [\(entry.level)]"
                                    )
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
                    ShareLink(item: logs.exportText)
                }
            }
        }
    }
}
