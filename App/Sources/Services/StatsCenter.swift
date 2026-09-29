import Combine
import Foundation
import SpeechLogic

/// Folds wall-clock time into StatsStore rows: every fold interval the
/// elapsed slice is recorded and the clock resets, so a killed app loses at
/// most one slice. `end()` flushes the trailing partial.
///
/// All calls land on the main thread (view lifecycle, scenePhase, Combine
/// subscriptions on RunLoop.main) — no locking here, the store locks its own
/// array.
final class StatsRecorder {
    let kind: StatsKind
    /// Cap per fold: normally a fold is ~interval wide; the cap only bounds
    /// the jump when iOS suspends the Task between folds (background) and
    /// time appears to leap.
    private var cap: TimeInterval
    private let interval: TimeInterval
    private var subjectId: String?
    private var startedAt: Date?
    private var task: Task<Void, Never>?

    init(kind: StatsKind, interval: TimeInterval = 30, cap: TimeInterval = 120) {
        self.kind = kind
        self.interval = interval
        self.cap = cap
    }

    /// Idempotent for the same subject; a subject switch ends the old run
    /// first (one fold, not a merged blob across subjects).
    func begin(subjectId: String) {
        if let current = self.subjectId {
            if current == subjectId, task != nil { return }
            end()
        }
        self.subjectId = subjectId
        startedAt = Date()
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.flushSlice()
            }
        }
    }

    func end() {
        flushSlice(cap: 3600)
        task?.cancel()
        task = nil
        subjectId = nil
        startedAt = nil
    }

    private func flushSlice(cap overrideCap: TimeInterval? = nil) {
        guard let subjectId, let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= 1 else { return }
        self.startedAt = Date()
        StatsStore.shared.record(subjectId: subjectId, kind: kind, seconds: min(elapsed, overrideCap ?? cap))
    }
}

/// One listening slot: tracks which subject the slot is recording and
/// switches/ends the recorder when the desired subject changes. The TTS
/// player and the audiobook player each get their own slot, so a read-along
/// book and an audiobook playing at once are both counted.
private final class ListeningSlot {
    let kind = StatsKind.listening
    private var recorder: StatsRecorder?
    private var subject: String?

    func sync(to newSubject: String?) {
        if newSubject == subject { return }
        recorder?.end()
        recorder = nil
        subject = newSubject
        if let newSubject {
            let recorder = StatsRecorder(kind: kind, interval: 15, cap: 300)
            recorder.begin(subjectId: newSubject)
            self.recorder = recorder
        }
    }
}

/// The recording funnel: reading surfaces own a StatsRecorder each (Batch B
/// wires the epub/PDF readers), and listening is derived here from the two
/// players' published state — zero hooks inside the playback engines.
///
/// Listening attribution: SpeechPlayer speaks BOTH notes and read-aloud
/// books; the book id wins when present, else the note id. AudioBookPlayer
/// plays audiobook files.
///
/// MainActor: it reads the players' @Published state (both player classes
/// are main-actor isolated) and every caller already lives on main.
@MainActor
final class StatsCenter {
    static let shared = StatsCenter()

    private let ttsSlot = ListeningSlot()
    private let audiobookSlot = ListeningSlot()
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    /// Call once after the players exist (app onAppear, deferred past the
    /// first frame like the other eager wiring).
    func attach(player: SpeechPlayer, audioBooks: AudioBookPlayer) {
        // The sinks deliver on RunLoop.main; the Task hop is what makes the
        // main-actor isolation visible to the compiler.
        player.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncTTS(player) }
            }
            .store(in: &cancellables)
        player.$nowPlayingNoteId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncTTS(player) }
            }
            .store(in: &cancellables)
        player.$nowPlayingBookId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncTTS(player) }
            }
            .store(in: &cancellables)

        audioBooks.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncAudiobook(audioBooks) }
            }
            .store(in: &cancellables)
        audioBooks.$activeBookID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncAudiobook(audioBooks) }
            }
            .store(in: &cancellables)
    }

    private func syncTTS(_ player: SpeechPlayer) {
        let subject: String?
        if player.state == .speaking {
            if let bookId = player.nowPlayingBookId {
                subject = bookId
            } else if let noteId = player.nowPlayingNoteId {
                subject = noteId.uuidString
            } else {
                subject = nil
            }
        } else {
            subject = nil
        }
        ttsSlot.sync(to: subject)
    }

    private func syncAudiobook(_ audioBooks: AudioBookPlayer) {
        audiobookSlot.sync(to: audioBooks.isPlaying ? audioBooks.activeBookID?.uuidString : nil)
    }
}
