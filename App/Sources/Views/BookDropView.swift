import SwiftUI

/// BookDrop — move books and JEX archives over the local network, in either
/// direction. SEND: pick a peer on this network and push a book, a note or a
/// .jex archive (LocalSend v2.2, works with the desktop LocalSend app).
/// RECEIVE: a PC running LocalSend sends to this iPhone; the receive side
/// needs no special entitlements because the sender does the discovering.
struct BookDropView: View {
    @ObservedObject private var receiver: LocalSendReceiver
    @AppStorage("bookDropEnabled") private var enabled = false
    @AppStorage("bookDropAutoAccept") private var autoAccept = true
    /// The optional receive-side access code. Written here, read by the
    /// receiver per prepare-upload (LocalSendReceiver.requiredPin) and
    /// offered as the sender-side field in BookDropSendView — same default
    /// key, so both halves can never drift.
    @AppStorage("bookDropPin") private var accessCode = ""

    /// The receiver is a @MainActor singleton — the default-value initializer
    /// would touch it from a nonisolated context, so the wiring is explicit.
    @MainActor init() {
        _receiver = ObservedObject(wrappedValue: LocalSendReceiver.shared)
        _enabled = AppStorage(wrappedValue: false, "bookDropEnabled")
        _autoAccept = AppStorage(wrappedValue: true, "bookDropAutoAccept")
        _accessCode = AppStorage(wrappedValue: "", "bookDropPin")
    }

    @State private var showingSend = false
    @State private var showingInfo = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Button {
                        Haptics.tap()
                        showingSend = true
                    } label: {
                        Label("Send to a device", systemImage: "paperplane.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!LocalSendSender.shared.canSend)

                    Button {
                        Haptics.tap()
                        toggleReceiver()
                    } label: {
                        Label(enabled ? "Stop" : "Start",
                              systemImage: enabled ? "stop.fill" : "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(enabled ? "Stop receiving" : "Start receiving")
                }
            }

            Section {
                Toggle("Nearby BookDrop", isOn: $enabled)
                if enabled {
                    LabeledContent("Status", value: statusText)
                    if receiver.isRunning {
                        LabeledContent("Port", value: String(receiver.port))
                    }
                    SecureField("Access code (optional)", text: $accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("Accept transfers automatically", isOn: $autoAccept)
            } header: {
                Text("Receive")
            }

            // A transfer streaming in right now: which file, and how much
            // of it has arrived.
            if let incoming = receiver.incomingTransfer {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(incoming.fileName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            if let fraction = incoming.fraction {
                                Text("\(Int((fraction * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let fraction = incoming.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                } header: {
                    Text("Receiving")
                }
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About BookDrop")
            }
        }
        .sheet(isPresented: $showingInfo) {
            BookDropInfoSheet(deviceAlias: deviceAlias)
        }
        // The access-code field must release the keyboard: tap outside or
        // drag the list.
        .scrollDismissesKeyboard(.immediately)
        .dismissesKeyboardOnTapOutside()
        .sheet(isPresented: $showingSend) {
            BookDropSendView()
        }
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

    private func toggleReceiver() {
        Haptics.tap()
        enabled.toggle()
    }

    private var deviceAlias: String {
        UIDevice.current.name
    }

    private var statusText: String {
        if receiver.isRunning {
            return "Visible on this network"
        }
        return receiver.lastError == nil ? "Starting…" : "Unavailable"
    }
}

/// The nav-bar info button's sheet: the setup steps and the privacy/protocol
/// facts the old footers carried, stated once (the EncryptionSettingsView
/// template — footers out, info button in).
private struct BookDropInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let deviceAlias: String

    var body: some View {
        NavigationStack {
            List {
                infoRow("What BookDrop moves",
                        "A book or audiobook, a note, an exported recording or a .jex archive — to a computer running LocalSend or another Speechnotes device, and back the other way.")
                infoRow("Sending from a PC",
                        "Open LocalSend on the computer (or another BookDrop app), pick the file and hit Send, then choose this iPhone (\(deviceAlias)) as the recipient. Books land on the Books shelf; JEX archives and markdown notes import into Notes; WAVs land in Storage.")
                infoRow("Receiving",
                        "Devices on the same network can send files to this iPhone once receiving is on. An access code, when set, must be typed on the sending device before any transfer starts.")
                infoRow("Stays on the network",
                        "Nothing leaves the local network and no account is involved.")
                infoRow("The protocol",
                        "BookDrop speaks the open LocalSend protocol — the same one the LocalSend desktop and mobile apps use.")
            }
            .navigationTitle("About BookDrop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
