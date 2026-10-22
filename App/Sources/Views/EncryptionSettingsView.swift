import SwiftUI

/// Settings → Encryption: the passphrase gate over the notes library.
///
/// Three states, one screen, no hidden modes:
///
/// * **off** — the notes file is plain JSON. The user sets a passphrase and
///   encryption begins; the library is sealed in place.
/// * **locked** — the file is sealed and no key is in memory. The notes
///   list shows a locked state (not an empty one); unlocking re-reads the
///   notes from disk.
/// * **unlocked** — notes read and write normally, sealed at rest. The
///   user can lock again (key dropped from memory) or turn encryption off
///   (file rewritten as plain JSON, key deleted).
///
/// The passphrase is never stored anywhere. Only the passphrase-wrapped
/// master key lives on the device, in the keychain — the same construction
/// Joplin uses, so a keychain backup restored onto another device cannot
/// be opened there.
struct EncryptionSettingsView: View {
    @EnvironmentObject private var notes: NotesStore
    @ObservedObject private var vault = EncryptionVault.shared

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var showingDisableConfirm = false
    /// True while the enable/unlock path is deriving the key — the
    /// passphrase KDF is 220 000 PBKDF2 iterations by design, so this is
    /// not instant.
    @State private var working = false

    var body: some View {
        Form {
            statusSection
            switch vaultState {
            case .off: enableSection
            case .locked: unlockSection
            case .unlocked: manageSection
            }
        }
        .navigationTitle("Encryption")
        .alert(
            "Encryption",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .alert("Turn off encryption?", isPresented: $showingDisableConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off", role: .destructive) { disable() }
        } message: {
            Text("Your notes are rewritten as a normal file and the key is deleted from this device. The passphrase is not needed again.")
        }
    }

    private enum VaultState {
        case off, locked, unlocked
    }

    private var vaultState: VaultState {
        if !vault.isEnabled { return .off }
        return vault.isUnlocked ? .unlocked : .locked
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: vault.isEnabled ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(vault.isEnabled ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notes.fileIsSealed ? "Notes are encrypted at rest" : "Notes are stored in a plain file")
                        .font(.subheadline.weight(.medium))
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Encryption uses the same format as Joplin: PBKDF2-HMAC-SHA512 (220 000 iterations) to wrap a 256-byte master key with your passphrase, then AES-256-GCM for the note text. A note encrypted here can be decrypted in Joplin, and one encrypted there decrypts here. The passphrase is never stored — if you forget it, the notes cannot be recovered.")
        }
    }

    private var statusDetail: String {
        switch vaultState {
        case .off:
            return "Anyone with the device unlocked, or a backup restored elsewhere, can read your notes."
        case .locked:
            return "Unlock with your passphrase to read and edit your notes."
        case .unlocked:
            return notes.fileIsSealed
                ? "The file on disk is sealed; notes stay readable while the app stays unlocked."
                : "Sealing the next write — the library will be encrypted at rest shortly."
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        Section {
            SecureField("Passphrase", text: $passphrase)
                .textContentType(.newPassword)
            SecureField("Confirm passphrase", text: $confirmation)
                .textContentType(.newPassword)
            Button {
                enable()
            } label: {
                HStack {
                    Spacer()
                    if working {
                        ProgressView()
                    } else {
                        Text("Turn on encryption")
                    }
                    Spacer()
                }
            }
            .disabled(!canEnable)
        } header: {
            Text("Set a passphrase")
        } footer: {
            Text("At least 8 characters. This runs 220 000 key-derivation iterations by design, so it takes a moment — a slow unlock is what makes a stolen file useless.")
        }
    }

    private var canEnable: Bool {
        !working && passphrase.count >= 8 && passphrase == confirmation
    }

    /// Turns encryption on and re-seals the library in place. The key
    /// derivation runs OFF the main actor (220 000 PBKDF2 iterations is a
    /// second and a half of CPU); only the vault activation and the file
    /// rewrite come back to the main actor.
    private func enable() {
        working = true
        let entered = passphrase
        Task { @MainActor in
            do {
                let material = try await Task.detached(priority: .userInitiated) {
                    try JoplinVaultKeyMaterial.create(passphrase: entered)
                }.value
                try vault.activate(material)
                let count = try notes.resealWithCurrentVault()
                passphrase = ""
                confirmation = ""
                Haptics.success()
                message = "Encryption is on. \(count) note(s) are now sealed at rest."
            } catch {
                Haptics.warning()
                message = (error as? LocalizedError)?.errorDescription
                    ?? (error as? JoplinVaultKeyMaterial.VaultError)?.description
                    ?? error.localizedDescription
            }
            working = false
        }
    }

    // MARK: - Unlock

    private var unlockSection: some View {
        Section {
            SecureField("Passphrase", text: $passphrase)
                .textContentType(.password)
            Button {
                unlock()
            } label: {
                HStack {
                    Spacer()
                    if working {
                        ProgressView()
                    } else {
                        Text("Unlock")
                    }
                    Spacer()
                }
            }
            .disabled(working || passphrase.isEmpty)
        } header: {
            Text("Unlock your notes")
        } footer: {
            Text("Your notes are on the device but encrypted. Unlock to read them; the key stays in memory until you lock again.")
        }
    }

    /// Unlocks the vault, then re-reads the sealed file from disk. The
    /// passphrase check itself runs detached (it is the same 220 000-
    /// iteration KDF as enable); the store reload is main-actor work.
    private func unlock() {
        working = true
        let entered = passphrase
        Task { @MainActor in
            defer {
                working = false
                self.passphrase = ""
            }
            do {
                guard let envelope = EncryptionVault.storedEnvelope() else {
                    throw JoplinVaultKeyMaterial.VaultError.noKeyOnDevice
                }
                let material = try await Task.detached(priority: .userInitiated) {
                    try JoplinVaultKeyMaterial.unwrap(envelope: envelope, passphrase: entered)
                }.value
                vault.activateUnlocked(material)
                guard notes.reloadAfterUnlock() != nil else {
                    throw JoplinVaultKeyMaterial.VaultError.wrongPassphrase
                }
                Haptics.success()
                message = nil
            } catch {
                Haptics.warning()
                message = (error as? LocalizedError)?.errorDescription
                    ?? (error as? JoplinVaultKeyMaterial.VaultError)?.description
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: - Manage

    private var manageSection: some View {
        Section {
            Button {
                vault.lock()
                Haptics.tap()
                message = "Locked. The key is out of memory; unlock again to read your notes."
            } label: {
                Label("Lock now", systemImage: "lock")
            }
            Button(role: .destructive) {
                showingDisableConfirm = true
            } label: {
                Label("Turn off encryption", systemImage: "lock.slash")
            }
        } header: {
            Text("Unlocked")
        } footer: {
            Text("Locking drops the key from memory — the notes stay sealed on disk and the app shows nothing until unlocked. Turning encryption off rewrites the notes file unencrypted and deletes the key from this device.")
        }
    }

    private func disable() {
        // Rewrite the file as plain JSON FIRST: once the key is gone there
        // is no way back to these notes, so a failure in between must leave
        // the sealed file (and its key) intact.
        do {
            try notes.resealWithCurrentVault(forcePlain: true)
        } catch {
            Haptics.warning()
            message = "Could not turn encryption off: \(error.localizedDescription). Your notes are untouched."
            return
        }
        vault.disable()
        Haptics.warning()
        message = "Encryption is off. Your notes are stored as a normal file."
    }
}
