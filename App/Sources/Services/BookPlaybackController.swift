import Foundation
import SpeechLogic

/// Drives TTS for books on top of the note playback machinery: ONE chapter
/// per speak call (engines chunk internally; chapter-sized units keep the
/// engine's chunk list bounded), auto-advance on natural completion via
/// SpeechPlayer.onNaturalFinish, and per-chapter speech text cached to disk
/// so replay/resume never re-extracts — and never needs the reader's
/// webview, which may not even exist while a book is playing.
@MainActor
final class BookPlaybackController {
    static let shared = BookPlaybackController()

    private weak var player: SpeechPlayer?
    private(set) var activeBook: Book?
    private(set) var activeChapterIndex = 0

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
        let alreadyActive = activeBook?.id == book.id
            && activeChapterIndex == chapterIndex
            && player.nowPlayingBookId == book.id.uuidString
        if alreadyActive, player.state != .idle {
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
                return
            }
            Log.shared.info("BookPlayback: ch\(index) of \(book.title) has no speech text — skipping")
            index += 1
        }
        Log.shared.info("BookPlayback: no speakable chapters from \(startIndex) in \(book.title)")
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
            activeBook = nil
            return
        }
        Task { [weak self] in
            await self?.speak(book: book, from: next)
        }
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
        let extracted: (text: String, pageOffsets: [PdfPageOffset]?)?
        switch book.format {
        case .epub:
            guard let spine = book.spine, chapterIndex < spine.count else { return nil }
            let archiveURL = BooksStore.originalFileURL(book)
            let entry = spine[chapterIndex]
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? Data(contentsOf: archiveURL, options: .mappedIfSafe),
                      let xhtml = try? ZipReader.readEntry(entry, in: data) else { return nil }
                let plain = XhtmlText.plainText(from: xhtml)
                return plain.isEmpty ? nil : plain
            }.value
            extracted = text.map { (text: $0, pageOffsets: nil as [PdfPageOffset]?) }
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
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
        if let pageOffsets = extracted?.pageOffsets,
           let data = try? JSONEncoder().encode(pageOffsets) {
            try? data.write(to: BooksStore.speechTextOffsetsURL(book, chapterIndex: chapterIndex), options: .atomic)
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
        player.export(text)
    }

    /// Warm the next chapter's cache while the current one plays so the
    /// chapter boundary in auto-advance is seamless.
    private func prefetchNextChapter(of book: Book, after chapterIndex: Int) {
        guard let spine = book.spine, chapterIndex + 1 < spine.count else { return }
        let next = chapterIndex + 1
        Task { [weak self] in
            _ = await self?.chapterText(for: book, chapterIndex: next)
        }
    }
}
