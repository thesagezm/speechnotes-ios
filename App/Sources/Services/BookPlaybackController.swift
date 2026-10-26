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
        // Lock-screen Previous/Next — SpeechPlayer forwards; we own the
        // chapter chain so the command becomes a chapter jump when a book
        // is active.
        player.onChapterSkip = { [weak self] delta in
            self?.skipChapters(by: delta)
        }
    }

    /// Lock-screen track-skip → chapter jump. A skip lands on the previous/
    /// next chapter from the SOUNDING one (not the viewed one), so a user
    /// listening while browsing keeps their place.
    private func skipChapters(by delta: Int) {
        guard let book = activeBook else { return }
        let target = max(0, min(Self.chapterCount(of: book) - 1, activeChapterIndex + delta))
        guard target != activeChapterIndex else { return }
        player?.stop()
        Task { [weak self] in
            await self?.speak(book: book, from: target)
        }
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

    /// A note/conversation takeover or an explicit stop nulls the book —
    /// chapter-skip goes back to grey.
    private func clearActiveBook() {
        activeBook = nil
        NowPlayingCenter.shared.setChapterSkipEnabled(false)
    }

    /// Where a play should begin, expressed by the SURFACE that owns the
    /// reading position. The readers pass what they are showing; the
    /// controller turns it into a UTF-16 offset once the chapter's speech
    /// text is known (the text length and the PDF page sidecar both need the
    /// resolved text first).
    enum BookStartPoint {
        /// The chapter's first sentence — the reader-mode Contents jump.
        case beginning
        /// A PDF page the reader is showing.
        case page(Int)
        /// Fraction (0…1) through the chapter — the EPUB reader's scroll
        /// position within the chapter.
        case fraction(Double)
    }

    /// The reader's play control. When this exact chapter is already the live
    /// speech, the underlying player handles pause/resume (text is not needed
    /// for those transitions); otherwise the chapter's text is resolved
    /// (disk cache → archive → XhtmlText) and spoken with a book bookmark
    /// primed for sentence-snapped resume.
    ///
    /// `from` carries the reader's current position: a FRESH play (no
    /// meaningful bookmark for this chapter) then starts at the page/spot the
    /// user is viewing instead of the chapter top. The player keeps the
    /// bookmark's priority — a real bookmark wins over the surface position.
    func togglePlay(book: Book, chapterIndex: Int, from startPoint: BookStartPoint? = nil) async {
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
        // Chapter skip buttons light up as soon as a book takes the player.
        NowPlayingCenter.shared.setChapterSkipEnabled(true)
        // Lock-screen dressing flows through the player (single writer —
        // a stray publish from the controller can't fight the player's own).
        player.nowPlayingPayload = SpeechPlayer.NowPlayingPayload(
            subtitle: nil, // set per-chapter in publishChapterLabel
            artworkPath: BooksStore.coverFileURL(book).path
        )
        activeBook = book
        await speak(book: book, from: chapterIndex, startPoint: startPoint)
    }

    /// The reader-mode Contents jump: while THIS book is sounding, a TOC tap
    /// moves the SPEECH to the chosen chapter — the read-along surface shows
    /// `activeSpeechText`, so it follows the moment the new chapter starts.
    /// Speaks the chapter from its start (an explicit "go to chapter N"), and
    /// the auto-advance chain stays armed. When nothing of this book is
    /// live it degrades to a plain play from that chapter.
    func jumpToChapter(book: Book, chapterIndex: Int) async {
        guard chapterIndex >= 0, chapterIndex < Self.chapterCount(of: book) else { return }
        if activeBook?.id == book.id,
           player?.nowPlayingBookId == book.id.uuidString,
           player?.state != .idle {
            await speak(book: book, from: chapterIndex, startPoint: .beginning)
        } else {
            await togglePlay(book: book, chapterIndex: chapterIndex)
        }
    }

    /// Foreground reconcile: the system suspended a backgrounded listening
    /// session and the player kept the book's bookmark. Resume the book at
    /// the chapter the bookmark held — the same dressing `togglePlay`
    /// applies, minus the toggle (nothing is live to toggle).
    func resumeBook(book: Book, from chapterIndex: Int) async {
        guard player != nil else { return }
        NowPlayingCenter.shared.setChapterSkipEnabled(true)
        player?.nowPlayingPayload = SpeechPlayer.NowPlayingPayload(
            subtitle: nil, // set per-chapter in publishChapterLabel
            artworkPath: BooksStore.coverFileURL(book).path
        )
        activeBook = book
        await speak(book: book, from: chapterIndex)
    }

    /// Speaks `from` onward, skipping chapters with no extractable text
    /// (cover-only epub files, image-only PDF pages). Re-arms onNaturalFinish
    /// after every start — explicit stop()s and note takeovers clear it on
    /// the player.
    ///
    /// `startPoint` carries the reader surface's position for a fresh play;
    /// nil keeps the historic priority (a meaningful stored bookmark
    /// resumes, else the chapter top). It resolves to a UTF-16 offset AFTER
    /// the chapter text is known — the fraction needs the text's length and
    /// the PDF page needs its offsets sidecar.
    private func speak(book: Book, from startIndex: Int, startPoint: BookStartPoint? = nil) async {
        guard let player else { return }
        let chapterCount = Self.chapterCount(of: book)
        var index = max(0, startIndex)
        while index < chapterCount {
            if let text = await chapterText(for: book, chapterIndex: index) {
                activeChapterIndex = index
                publishChapterLabel(for: book, chapterIndex: index)
                player.nowPlayingPayload.subtitle = nowPlayingChapterLabel
                prefetchNextChapter(of: book, after: index)
                player.onNaturalFinish = { [weak self] in
                    self?.advanceToNextChapter()
                }
                let startOffset = await speechStartOffset(
                    for: startPoint,
                    book: book,
                    chapterIndex: index,
                    textLength: text.utf16.count
                )
                let ref = SpeechPlayer.BookPlaybackRef(
                    id: book.id.uuidString,
                    title: book.title,
                    chapterIndex: index,
                    startOffset: startOffset
                )
                if player.nowPlayingBookId == book.id.uuidString, player.state != .idle {
                    // The reader-mode Contents jump (jumpToChapter): THIS
                    // book is already sounding and the user picked another
                    // chapter. togglePlay would only pause it, and stop()
                    // would flicker the read-along surface away and wipe the
                    // lock screen — so supersede IN PLACE. playFrom keeps the
                    // auto-advance chain armed and swaps the read-along text
                    // to the new chapter the moment the engine starts it.
                    player.playFrom(text, at: startOffset ?? 0, book: ref)
                } else {
                    player.togglePlay(text, note: nil, book: ref)
                }
                // NOT endChapterGapGrace() here: the grace's whole job is
                // the window this call just opened (first-chunk render).
                endChapterGapGraceWhenSpeakingBegins()
                return
            }
            Log.shared.info("BookPlayback: ch\(index) of \(book.title) has no speech text — skipping")
            index += 1
        }
        Log.shared.info("BookPlayback: no speakable chapters from \(startIndex) in \(book.title)")
        endChapterGapGrace()
        clearActiveBook()
    }

    /// Turns a reader surface's position into a UTF-16 offset into the
    /// chapter's speech text. nil means "no usable position" — SpeechPlayer
    /// then keeps its own priority (a meaningful bookmark wins, else the
    /// chapter top). A position at the very start of the text reports nil
    /// too: the user is looking at the chapter's first page, so a bookmark
    /// for this chapter must still win ("page 1 is not really a bookmark" —
    /// the user's words). Only the explicit .beginning jump forces 0.
    private func speechStartOffset(for point: BookStartPoint?, book: Book, chapterIndex: Int, textLength: Int) async -> Int? {
        switch point {
        case .beginning:
            return 0
        case .fraction(let fraction):
            let clamped = min(max(fraction, 0), 1)
            guard clamped > 0.001 else { return nil }
            return min(Int(clamped * Double(textLength)), textLength - 1)
        case .page(let page):
            return await pdfPageStartOffset(page: page, book: book, chapterIndex: chapterIndex, textLength: textLength)
        case nil:
            return nil
        }
    }

    /// Where `page`'s text starts in the chapter's speech text — the
    /// per-page offsets sidecar written at extraction time (the same file
    /// read-along page tracking uses). nil when the sidecar is missing (a
    /// cache from before it existed), the page precedes any text, or the
    /// entry sits at/off the text's ends: SpeechPlayer then falls back to
    /// bookmark-or-chapter-top. A page whose neighbors were image-only
    /// resolves to the nearest preceding page that HAS text — the honest
    /// best for a scan with blank pages.
    private func pdfPageStartOffset(page: Int, book: Book, chapterIndex: Int, textLength: Int) async -> Int? {
        let url = BooksStore.speechTextOffsetsURL(book, chapterIndex: chapterIndex)
        let offsets: [PdfPageOffset] = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder().decode([PdfPageOffset].self, from: data)) ?? []
        }.value
        guard let entry = offsets.last(where: { $0.page <= page }) else { return nil }
        guard entry.utf16Offset > 0, entry.utf16Offset < textLength else { return nil }
        return entry.utf16Offset
    }

    /// Format-neutral speech units: epub = spine items, pdf = manifest
    /// chapters (outline / heading / page-range resolved).
    static func chapterCount(of book: Book) -> Int {
        switch book.format {
        case .epub: return book.spine?.count ?? 0
        case .pdf: return book.pdfChapters?.count ?? 0
        case .audio: return book.audioChapters?.count ?? 0
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
            clearActiveBook()
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
    /// How many ~30 s tasks this gap has chained. One task covers the
    /// cached-text resolve; an UNCACHED chapter (epub zip parse, PDF Vision
    /// OCR) or a thermally-throttled first render can outrun it, and the
    /// gap is precisely when nothing else holds the audio assertion — the
    /// old chapter's engine stopped, the new one starts on first schedule.
    /// Bounded chaining keeps the book alive through those windows without
    /// becoming a general keep-alive (the chain ends the moment speech is
    /// audible again — see `endChapterGapGraceWhenSpeakingBegins`).
    private var chapterGapArms = 0
    private static let chapterGapMaxArms = 3

    private func beginChapterGapGrace() {
        endChapterGapGrace()
        chapterGapArms = 1
        armChapterGapGrace()
    }

    private func armChapterGapGrace() {
        chapterGapTask = UIApplication.shared.beginBackgroundTask(withName: "BookChapterGap") { [weak self] in
            // The expiration handler runs off-main; hop to the actor before
            // touching player state or UIKit.
            Task { @MainActor in
                self?.chapterGapGraceExpired()
            }
        }
    }

    /// The system reclaimed one task's worth of grace. If the book is still
    /// mid-transition (chain armed, speech not yet sounding), chain another
    /// bounded task; otherwise stand down.
    private func chapterGapGraceExpired() {
        endChapterGapGraceTask()
        guard chapterGapArms < Self.chapterGapMaxArms,
              let player,
              activeBook != nil,
              player.state == .idle || player.state == .generating else {
            chapterGapArms = 0
            return
        }
        chapterGapArms += 1
        Log.shared.info("BookPlayback: chapter-gap grace expired mid-transition — chaining task \(chapterGapArms) of \(Self.chapterGapMaxArms)")
        armChapterGapGrace()
    }

    /// Ends the TASK only; a chained expiration keeps the arm count.
    private func endChapterGapGraceTask() {
        guard chapterGapTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(chapterGapTask)
        chapterGapTask = .invalid
    }

    private func endChapterGapGrace() {
        endChapterGapGraceTask()
        chapterGapArms = 0
    }

    /// The grace exists to bridge "nothing is sounding" — the old chapter
    /// ended, the next chapter's first chunk is still rendering. `togglePlay`
    /// only OPENS that window (state goes `.generating`), so ending the
    /// task at the call itself covered none of it: the moment of maximum
    /// vulnerability was exactly the one the grace was dropped in. End it
    /// when audio is actually sounding, or after 25 s (by then the core's
    /// background keepalive has the render chain bridging on its own).
    private func endChapterGapGraceWhenSpeakingBegins() {
        let deadline = Date().addingTimeInterval(25)
        Task { [weak self] in
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.chapterGapTask != .invalid else { return }
                if self.player?.state == .speaking {
                    self.endChapterGapGrace()
                    return
                }
            }
            self?.endChapterGapGrace()
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
        case .audio:
            // An audiobook's speech text is its own chapter metadata — the
            // engine path never runs for it, and this only feeds the reader's
            // chapter label and any export the user asks for.
            guard let chapters = book.audioChapters, chapterIndex < chapters.count else { return nil }
            extracted = (chapters[chapterIndex].title, nil as [PdfPageOffset]?)
        }
        guard let rawText = extracted?.text, !rawText.isEmpty else { return nil }
        // Sanitised at this boundary, before the cache write, so the chapter
        // text on disk is already speakable — every later read of it (resume,
        // auto-advance, export, read-along) sees the same bytes, and a book
        // imported yesterday is cleaned by the same pass that a book imported
        // tomorrow gets.
        var text = SpeechText.forText(rawText)
        if text.isEmpty {
            Log.shared.info("BookPlayback: ch\(chapterIndex) of \(book.title) has no speakable text after cleaning")
            return nil
        }
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
