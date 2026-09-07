import Foundation
import UIKit
import SpeechLogic

/// Drives TTS for books on top of the note playback machinery: ONE chapter
/// per speak call (engines chunk internally; chapter-sized units keep the
/// engine's chunk list bounded), auto-advance on natural completion via
/// SpeechPlayer.onNaturalFinish, and per-chapter speech text cached to disk
/// so replay/resume never re-extracts — and never needs the reader's
/// webview, which may not even exist while a book is playing.
@MainActor
final class BookPlaybackController: ObservableObject {
    static let shared = BookPlaybackController()

    private weak var player: SpeechPlayer?
    private(set) var activeBook: Book?
    @Published private(set) var activeChapterIndex = 0
    /// "Ch 12 — The Reunion" style label for the reader's player bar —
    /// during auto-advance the user otherwise can't tell WHICH chapter is
    /// sounding. Resolved from the manifest TOC when one exists.
    @Published private(set) var nowPlayingChapterLabel: String?

    /// Wired once from SpeechnotesApp's onAppear (same launch-hygiene window
    /// as notesProvider).
    func bind(to player: SpeechPlayer) {
        self.player = player
    }

    /// True when THIS book+chapter is the live speech — drives the reader's
    /// play button state and the read-along swap.
    func isPlaying(book: Book, chapterIndex: Int) -> Bool {
        guard let player else { return false }
        return activeBook?.id == book.id
            && activeChapterIndex == chapterIndex
            && player.nowPlayingBookId == book.id.uuidString
            && player.state != .idle
    }

    /// True while any part of this book is on the player.
    func isBookActive(_ book: Book) -> Bool {
        guard let player else { return false }
        return player.nowPlayingBookId == book.id.uuidString && player.state != .idle
    }

    /// The reader's play control. When this exact chapter is already the live
    /// speech, the underlying player handles pause/resume (text is not needed
    /// for those transitions); otherwise the chapter's text is resolved
    /// (disk cache → archive → XhtmlText) and spoken with a book bookmark
    /// primed for sentence-snapped resume.
    func togglePlay(book: Book, chapterIndex: Int) async {
        guard let player else { return }
        let ref = SpeechPlayer.BookPlaybackRef(
            id: book.id.uuidString,
            title: book.title,
            chapterIndex: chapterIndex
        )
        // The reader bar shows "pause" whenever THIS book is the live
        // speech — even if the user has scrolled to a different chapter
        // than the one sounding. A tap there must pause/resume the ONGOING
        // session, not re-speak the viewed chapter and silently abandon
        // auto-advance.
        if player.nowPlayingBookId == book.id.uuidString, player.state != .idle {
            player.togglePlay("", note: nil, book: ref)
            return
        }
        activeBook = book
        await speak(book: book, from: chapterIndex)
    }

    /// Speaks `from` onward, skipping chapters with no extractable text
    /// (cover-only epub files, image-only PDF pages). Re-arms onNaturalFinish
    /// after every start — explicit stop()s and note takeovers clear it on
    /// the player.
    private func speak(book: Book, from startIndex: Int) async {
        guard let player else { return }
        let chapterCount = Self.chapterCount(of: book)
        var index = max(0, startIndex)
        while index < chapterCount {
            if let text = await chapterText(for: book, chapterIndex: index) {
                activeChapterIndex = index
                publishChapterLabel(for: book, chapterIndex: index)
                prefetchNextChapter(of: book, after: index)
                player.onNaturalFinish = { [weak self] in
                    self?.advanceToNextChapter()
                }
                player.togglePlay(
                    text,
                    note: nil,
                    book: SpeechPlayer.BookPlaybackRef(
                        id: book.id.uuidString,
                        title: book.title,
                        chapterIndex: index
                    )
                )
                endChapterGapGrace()
                return
            }
            Log.shared.info("BookPlayback: ch\(index) of \(book.title) has no speech text — skipping")
            index += 1
        }
        Log.shared.info("BookPlayback: no speakable chapters from \(startIndex) in \(book.title)")
        endChapterGapGrace()
        activeBook = nil
    }

    /// Format-neutral speech units: epub = spine items, pdf = manifest
    /// chapters (outline / heading / page-range resolved).
    static func chapterCount(of book: Book) -> Int {
        switch book.format {
        case .epub: return book.spine?.count ?? 0
        case .pdf: return book.pdfChapters?.count ?? 0
        }
    }

    private func advanceToNextChapter() {
        guard let book = activeBook else { return }
        let next = activeChapterIndex + 1
        guard next < Self.chapterCount(of: book) else {
            Log.shared.info("BookPlayback: finished \(book.title)")
            Haptics.success()
            ToastCenter.shared.show("Finished \"\(book.title.prefix(40))\"")
            endChapterGapGrace()
            activeBook = nil
            return
        }
        // Between chapters NOTHING is playing, so iOS may suspend the app
        // despite the audio background mode — the book stops mid-listen.
        // A background grace task bridges the gap (chapter text resolve +
        // first-chunk generation) and ends once the next chapter speaks.
        beginChapterGapGrace()
        Task { [weak self] in
            await self?.speak(book: book, from: next)
        }
    }

    // MARK: - Chapter-gap background grace

    private var chapterGapTask: UIBackgroundTaskIdentifier = .invalid

    private func beginChapterGapGrace() {
        endChapterGapGrace()
        chapterGapTask = UIApplication.shared.beginBackgroundTask(withName: "BookChapterGap") { [weak self] in
            self?.endChapterGapGrace()
        }
    }

    private func endChapterGapGrace() {
        guard chapterGapTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(chapterGapTask)
        chapterGapTask = .invalid
    }

    /// Chapter speech text: disk cache first, then extract off-main and cache
    /// for every later play/resume. epub = one zip entry → XhtmlText; pdf =
    /// per-page PdfText extraction with Vision OCR for scanned pages, plus
    /// the per-page offsets sidecar for read-along page sync.
    private func chapterText(for book: Book, chapterIndex: Int) async -> String? {
        let cacheURL = BooksStore.speechTextURL(book, chapterIndex: chapterIndex)
        if let cached = try? String(contentsOf: cacheURL, encoding: .utf8), !cached.isEmpty {
            return cached
        }
        var suspectParse = false
        let extracted: (text: String, pageOffsets: [PdfPageOffset]?)?
        switch book.format {
        case .epub:
            guard let spine = book.spine, chapterIndex < spine.count else { return nil }
            let archiveURL = BooksStore.originalFileURL(book)
            let entry = spine[chapterIndex]
            let result = await Task.detached(priority: .userInitiated) { () -> (text: String, parseCompleted: Bool)? in
                guard let data = try? Data(contentsOf: archiveURL, options: .mappedIfSafe),
                      let xhtml = try? ZipReader.readEntry(entry, in: data) else { return nil }
                let extraction = XhtmlText.extract(from: xhtml)
                return extraction.text.isEmpty ? nil : (extraction.text, extraction.parseCompleted)
            }.value
            // A parse that aborted mid-document (rare after the entity
            // pre-pass, still possible) must NOT be cached — the truncated
            // text would replay on every future play/resume with no error.
            if let result, !result.parseCompleted {
                suspectParse = true
                Log.shared.error("BookPlayback: ch\(chapterIndex) of \(book.title) — XML parse aborted near char \(result.text.utf16.count); NOT caching")
            }
            extracted = result.map { (text: $0.text, pageOffsets: nil as [PdfPageOffset]?) }
        case .pdf:
            guard let result = await PdfSpeechText.chapterText(book: book, chapterIndex: chapterIndex) else {
                return nil
            }
            extracted = (result.text, result.pageOffsets)
        }
        guard var text = extracted?.text, !text.isEmpty else { return nil }
        if text.utf16.count > 200_000 {
            Log.shared.info("BookPlayback: ch\(chapterIndex) is \(text.utf16.count) chars — engines may take a while")
        }
        if !suspectParse {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
        if let pageOffsets = extracted?.pageOffsets,
           let data = try? JSONEncoder().encode(pageOffsets) {
            try? data.write(to: BooksStore.speechTextOffsetsURL(book, chapterIndex: chapterIndex), options: .atomic)
        }
        }
        return text
    }

    /// Renders ONE chapter to a WAV and hands the file to the share sheet
    /// (player.shareURL). `player.export` stops playback first — the single
    /// engine slot belongs to the exporter while it runs — and memory stays
    /// bounded: one chapter, never the whole book (the OOM rule).
    func exportChapter(book: Book, chapterIndex: Int) async {
        guard let player else { return }
        guard let text = await chapterText(for: book, chapterIndex: chapterIndex) else {
            Log.shared.info("BookPlayback: export — ch\(chapterIndex) of \(book.title) has no speech text")
            return
        }
        player.export(text, title: book.title)
    }

    /// Resolves the sounding chapter's display label from the manifest TOC
    /// (first entry pointing at this spine index), falling back to the
    /// chapter number.
    private func publishChapterLabel(for book: Book, chapterIndex: Int) {
        let count = Self.chapterCount(of: book)
        let number = count > 0 ? "Ch \(chapterIndex + 1) of \(count)" : "Ch \(chapterIndex + 1)"
        if let toc = book.toc,
           let entry = toc.first(where: { $0.spineIndex == chapterIndex }), !entry.label.isEmpty {
            nowPlayingChapterLabel = entry.label.count <= 48 ? entry.label : String(entry.label.prefix(46)) + "…"
        } else {
            nowPlayingChapterLabel = number
        }
    }

    /// Warm upcoming chapters while the current one plays so the chapter
    /// boundary in auto-advance is seamless. Loops past chapters with no
    /// extractable text — warming exactly index+1 doubled the gap precisely
    /// when the next item was a cover/image-only unit.
    private func prefetchNextChapter(of book: Book, after chapterIndex: Int) {
        Task { [weak self] in
            var index = chapterIndex + 1
            while index < Self.chapterCount(of: book) {
                if await self?.chapterText(for: book, chapterIndex: index) != nil { break }
                index += 1
            }
        }
    }
}
