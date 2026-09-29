import SwiftUI

/// BookDrop — receive books and JEX archives over the local network from a
/// PC running LocalSend (or another BookDrop/LocalSend receiver-protocol
/// app). The receive-only half of the LocalSend protocol: the sender does
/// all the discovering, so the iPhone needs no special entitlements.
struct BookDropView: View {
    @ObservedObject private var receiver: LocalSendReceiver
    @AppStorage("bookDropEnabled") private var enabled = false
    @AppStorage("bookDropAutoAccept") private var autoAccept = true

    /// The receiver is a @MainActor singleton — the default-value initializer
    /// would touch it from a nonisolated context, so the wiring is explicit.
    @MainActor init() {
        _receiver = ObservedObject(wrappedValue: LocalSendReceiver.shared)
        _enabled = AppStorage(wrappedValue: false, "bookDropEnabled")
        _autoAccept = AppStorage(wrappedValue: true, "bookDropAutoAccept")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Nearby BookDrop", isOn: $enabled)
                if enabled {
                    LabeledContent("Status", value: statusText)
                    if receiver.isRunning {
                        LabeledContent("Port", value: String(receiver.port))
                    }
                }
                Toggle("Accept transfers automatically", isOn: $autoAccept)
            } header: {
                Text("Receive")
            } footer: {
                Text("Devices on the same Wi-Fi can send files to this iPhone. Nothing leaves the network and no account is involved.")
            }

            Section {
                instructionRow(
                    step: "1",
                    text: "Open LocalSend on your computer (or another BookDrop app)."
                )
                instructionRow(
                    step: "2",
                    text: "Pick your .jex archive, an .epub, a PDF or an audiobook and hit Send."
                )
                instructionRow(
                    step: "3",
                    text: "Choose this iPhone (\(deviceAlias)) as the recipient. Books land on the Books shelf; JEX archives import into Notes."
                )
            } header: {
                Text("How to send from a PC")
            } footer: {
                Text("BookDrop speaks the open LocalSend protocol — the same one the LocalSend desktop and mobile apps use.")
            }

            Section("Recent transfers") {
                if receiver.history.isEmpty {
                    Text("Nothing yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(receiver.history) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                switch record.outcome {
                                case .imported(let detail):
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(detail)
                                case .failed(let detail):
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(detail)
                                case .rejected:
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                    Text("Rejected")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let lastError = receiver.lastError {
                Section {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("BookDrop")
        .onChange(of: enabled) { newValue in
            receiver.setEnabled(newValue)
        }
        .onChange(of: autoAccept) { newValue in
            receiver.autoAccept = newValue
        }
        .onAppear {
            // Keep the receiver's mirror of the toggle in sync (it is the
            // source of truth for the launch-time auto-start).
            receiver.autoAccept = autoAccept
            if enabled, !receiver.isRunning {
                receiver.start()
            }
        }
    }

    private var deviceAlias: String {
        UIDevice.current.name
    }

    private var statusText: String {
        if receiver.isRunning {
            return "Visible on this Wi-Fi"
        }
        return receiver.lastError == nil ? "Starting…" : "Unavailable"
    }

    private func instructionRow(step: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(step)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
