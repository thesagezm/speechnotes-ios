import Foundation
import UIKit
import PDFKit
import AVFoundation
import SpeechLogic

/// The Books library. Each book is a self-contained directory under
/// Documents/Books/<uuid>/ holding the original file, a manifest.json, a
/// cover image and (from the TTS phase on) cached per-chapter speech text.
///
/// Storage model matters here: one manifest PER BOOK, never one big file —
/// the notes store rewrites its whole JSON on every save flush, which is
/// fine for notes and would be wasteful next to 50 MB books. Scanning the
/// shelf means decoding a handful of tiny manifests.
@MainActor
final class BooksStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    /// Binned books, most recently deleted first — the books recycle bin.
    /// Optional in the manifest (`Book.deletedAt`), so a shelf written
    /// before the bin existed decodes as an empty bin.
    var deletedBooks: [Book] {
        allBooks
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }
    /// Everything on disk, active or binned — the raw shelf + the bin.
    private var allBooks: [Book] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?

    // MARK: - Locations
    // All static helpers are `nonisolated` so the detached manifest builder
    // can use them off the main actor.

    nonisolated static var booksDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
    }

    nonisolated static func bookDirectory(_ id: UUID) -> URL {
        booksDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    nonisolated static func originalFileURL(_ book: Book) -> URL {
        bookDirectory(book.id).appendingPathComponent("original.\(book.format.rawValue)")
    }

    /// The audio book's file, resolved to whatever name it actually carries.
    /// New imports store `original.<true extension>` (AVURLAsset needs a real
    /// container extension to read metadata/chapters/covers); books imported
    /// before round 5 still have `original.audio`, which keeps playing but
    /// parses as nothing. Probing is one small directory listing, only for
    /// the audio format.
    nonisolated static func resolveAudioOriginalURL(book: Book) -> URL {
        let dir = bookDirectory(book.id)
        for ext in ["m4b", "m4a", "mp3", "mp4"] where FileManager.default.fileExists(atPath: dir.appendingPathComponent("original.\(ext)").path) {
            return dir.appendingPathComponent("original.\(ext)")
        }
        return dir.appendingPathComponent("original.audio")
    }

    /// Legacy `original.audio` → sniffed true extension (ID3 head → mp3,
    /// otherwise the MPEG-4 family → m4b). Renames once, at the manifest
    /// backfill, so AVURLAsset can actually read the file.
    nonisolated private static func renameLegacyAudioFileIfNeeded(book: Book, directory: URL) {
        let legacy = directory.appendingPathComponent("original.audio")
        guard book.format == .audio, FileManager.default.fileExists(atPath: legacy.path) else { return }
        guard let handle = try? FileHandle(forReadingFrom: legacy) else { return }
        let head = handle.readData(ofLength: 16)
        try? handle.close()
        let isMP3 = head.starts(with: [0x49, 0x44, 0x33]) // "ID3"
        let target = directory.appendingPathComponent("original.\(isMP3 ? "mp3" : "m4b")")
        guard !FileManager.default.fileExists(atPath: target.path) else {
            try? FileManager.default.removeItem(at: legacy)
            return
        }
        try? FileManager.default.moveItem(at: legacy, to: target)
    }

    nonisolated static func coverFileURL(_ book: Book) -> URL {
        bookDirectory(book.id).appendingPathComponent("cover.jpg")
    }

    /// Cancellation token for the in-flight shelf backfill. Replaced per
    /// pass; the watchdog cancels the current one when it sees the main
    /// thread blocked.
    private var backfillCancellation: BookBackfillCancellation = BookBackfillCancellation()

    /// One backfill pass's cancellation token.
    final class BookBackfillCancellation {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    /// Called by the HangWatchdog: abandon the current shelf pass so the
    /// main thread stops competing with it, and clear the one-shot flag so
    /// the next shelf open tries again (a cancelled pass is not a completed
    /// one).
    func cancelShelfBackfill() {
        guard !backfillCancellation.isCancelled else { return }
        backfillCancellation.cancel()
        didBackfillLegacyBooks = false
        Log.shared.info("BooksStore: shelf backfill cancelled by the hang watchdog — will retry next open")
    }

    // MARK: - Audiobook parse slices

    /// How much of an audiobook the chapter readers look at: moov sits at
    /// the head (+faststart) or the tail (plain ffmpeg), so head+tail is
    /// enough for anything real. The old code mapped the WHOLE file, which
    /// on a 266 MB m4b was seconds of page faults on the utility queue —
    /// the "tap any book and the app freezes" report.
    nonisolated static let audioParseHeadBytes = 8 * 1024 * 1024
    nonisolated static let audioParseTailBytes = 8 * 1024 * 1024

    /// `length` bytes starting at `from`, clamped to the file's size.
    nonisolated static func slice(of url: URL, from offset: Int64, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard offset >= 0 else { return nil }
        let start = UInt64(offset)
        guard let size = try? handle.seekToEnd(), start < size else { return nil }
        try? handle.seek(toOffset: start)
        let want = UInt64(max(0, length))
        return handle.readData(ofLength: Int(min(want, size - start)))
    }

    nonisolated static func fileSize(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }

    /// Cached speech text for one chapter (written by the TTS phase; the
    /// reader path never has to re-extract a chapter it already spoke).
    nonisolated static func speechTextURL(_ book: Book, chapterIndex: Int) -> URL {
        bookDirectory(book.id)
            .appendingPathComponent("text", isDirectory: true)
            .appendingPathComponent(String(format: "%04d.txt", chapterIndex))
    }

    /// Read-along page-sync sidecar for PDF chapters: where each page's text
    /// starts (UTF-16) inside the chapter's speech text, so the reader can
    /// auto-scroll the PDFView to the sounding page.
    nonisolated static func speechTextOffsetsURL(_ book: Book, chapterIndex: Int) -> URL {
        bookDirectory(book.id)
            .appendingPathComponent("text", isDirectory: true)
            .appendingPathComponent(String(format: "%04d.pages.json", chapterIndex))
    }

    nonisolated static func manifestURL(_ id: UUID) -> URL {
        bookDirectory(id).appendingPathComponent("manifest.json")
    }

    /// For the Settings → Storage usage breakdown.
    nonisolated static func directorySize() -> Int64 {
        ExportsStore.directorySize(booksDirectory)
    }

    // MARK: - Shelf

    /// Called on tab open — never at launch (LiveContainer launch hygiene:
    /// no file I/O inside the first render).
    ///
    /// MANIFEST DECODE ONLY: each book is one small manifest.json, so the
    /// shelf is a directory listing plus N tiny decodes — cheap. The audio
    /// backfill below used to re-open every pending audiobook's FULL FILE
    /// (a memory map of the whole m4b, an AVURLAsset duration load, a sync
    /// chapterMetadataGroups, then a complete top-level box walk touching
    /// every mdat chunk). For a 266 MB book that was seconds of wall time
    /// on a utility queue competing with the main thread's I/O — the
    /// "tapping any book freezes the app" report. The audio backfill is
    /// now ONE BOOK PER LAUNCH (oldest first) and everything else about it
    /// is unchanged.
    private var watchdogObserverInstalled = false

    private func installWatchdogObserverOnce() {
        guard !watchdogObserverInstalled else { return }
        watchdogObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: .hangWatchdogFired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelShelfBackfill() }
        }
    }

    func refresh() {
        installWatchdogObserverOnce()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: Self.booksDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return }
        var shelf: [Book] = []
        for dir in dirs {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let book = try? JSONDecoder().decode(Book.self, from: data) else { continue }
            shelf.append(book)
        }
        allBooks = shelf.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
        books = allBooks.filter { !$0.isDeleted }
        pruneExpiredBooks()
        backfillMissingBooks(maxAudioBooks: 1)
    }

    /// One backfill pass per launch: PDFs/EPUBs imported before covers,
    /// spine lists or nested TOCs existed get them filled in, and
    /// `maxAudioBooks` (default 1) audio books get their manifest re-read
    /// from the file. One detached pass, then the shelf refreshes.
    ///
    /// The audio book re-read is EXPENSIVE by nature — it maps the whole
    /// m4b and walks its box tree — so it is capped (oldest book first) and
    /// deferred behind everything else. With N pending audio books the
    /// shelf repaired one per launch rather than seconds of I/O on every
    /// launch.
    private var didBackfillLegacyBooks = false

    private func backfillMissingBooks(maxAudioBooks: Int = 1) {
        guard !didBackfillLegacyBooks else { return }
        let pending = books.filter { book in
            (book.format == .pdf && (!book.hasCover || book.pdfChapters == nil))
                || (book.format == .epub && book.spine == nil)
                // Round 6: epubs with a FLAT toc (every depth nil — parsed
                // before the drop-down TOC existed) get one re-parse so the
                // tree can render.
                || (book.format == .epub && book.spine != nil
                    && !(book.toc ?? []).isEmpty
                    && (book.toc ?? []).allSatisfy { $0.depth == nil })
                // v1.7.1: books imported before the chapter-TRACK parser and
                // the awaited-metadata cover fix need one re-read of their
                // manifest — single-chapter audio with a "chpl" source that
                // never had chpl, and cover-less M4Bs that do carry art.
                // Round 5: also every audio book whose manifest was read from
                // a file AVURLAsset could not parse (the .audio extension).
                || (book.format == .audio && (!book.hasCover
                    || book.audioChapterSource == nil
                    || book.audioChapterSource == "single"
                    || book.audioChapterSource == "chpl"
                    || book.audioChapterSource == "mp4"
                    || book.audioChapterSource == "id3"))
        }
        guard !pending.isEmpty else { return }
        didBackfillLegacyBooks = true
        // Audio books: oldest added first, at most `maxAudioBooks`. Other
        // formats are cheap (a page render, a spine parse) and all go.
        let orderedPending = pending
        let capped: [Book] = {
            let others = orderedPending.filter { $0.format != .audio }
            let audio = orderedPending.filter { $0.format == .audio }
                .sorted { $0.addedAt < $1.addedAt }
                .prefix(maxAudioBooks)
            return others + audio
        }()
        // Cancellable: if the HangWatchdog sees the main thread blocked
        // while this pass runs (a slow PDF render, a cold disk), the pass
        // is abandoned instead of continuing to compete for I/O — the
        // freeze stops being terminal. The audit's AP2 guard applies:
        // this loop checks the token between books, not per byte.
        let cancellation = BookBackfillCancellation()
        backfillCancellation = cancellation
        Task.detached(priority: .utility) { [weak self] in
            for var book in capped {
                if cancellation.isCancelled { break }
                let dir = BooksStore.bookDirectory(book.id)
                switch book.format {
                case .pdf:
                    guard let document = PDFDocument(url: dir.appendingPathComponent("original.pdf")),
                          document.pageCount > 0 else { continue }
                    if !book.hasCover, let page = document.page(at: 0),
                       let data = Self.renderPDFCover(page: page) {
                        try? data.write(to: dir.appendingPathComponent("cover.jpg"), options: .atomic)
                        book.hasCover = true
                    }
                    // Books imported before v1.5 have no chapter list — the
                    // outline/heading/page-range resolver fills it in here.
                    if book.pdfChapters == nil {
                        let resolved = PdfText.resolveChapters(in: document)
                        if !resolved.chapters.isEmpty {
                            book.pdfChapters = resolved.chapters
                            book.pdfChapterSource = resolved.source
                        }
                    }
                case .audio:
                    // Round 5: legacy books kept their file as original.audio
                    // — an extension AVURLAsset cannot map to a container
                    // parser, so title/chapters/duration/cover all read back
                    // empty while playback (content-sniffing AVAudioPlayer)
                    // kept working. Give the file its true extension, then
                    // re-read the manifest from it.
                    Self.renameLegacyAudioFileIfNeeded(book: book, directory: dir)
                    let refreshed = Self.buildAudioManifest(book: book, directory: dir)
                    book = refreshed
                case .epub:
                    guard let data = try? Data(contentsOf: dir.appendingPathComponent("original.epub"), options: .mappedIfSafe),
                          let info = try? EpubParser.parse(archive: data), !info.spine.isEmpty else { continue }
                    book.spine = info.spine
                    book.spineCount = info.spine.count
                    if book.toc?.contains(where: { $0.depth != nil }) != true, !info.toc.isEmpty {
                        let indexByHref = Dictionary(info.spine.enumerated().map { ($1, $0) },
                                                     uniquingKeysWith: { first, _ in first })
                        book.toc = info.toc.map { entry in
                            BookTocEntry(label: entry.label, href: entry.href, spineIndex: indexByHref[entry.href])
                        }
                    }
                }
                if let manifest = try? JSONEncoder().encode(book) {
                    try? manifest.write(to: BooksStore.manifestURL(book.id), options: .atomic)
                }
            }
            await MainActor.run { [weak self] in
                self?.refresh()
            }
        }
    }

    // MARK: - Import

    /// Imports one book from a URL the caller already holds security scope
    /// for (the fileImporter pattern used across the app). The copy is
    /// synchronous and fast (one sequential file); the metadata parse and
    /// cover extraction run detached so a slow/corrupt file can never block
    /// the UI. Metadata failure downgrades to a filename-titled book — a
    /// book that parses badly is still a book. Returns the imported book,
    /// or nil when the copy/manifest write failed (importError is set).
    @discardableResult
    func importBook(from sourceURL: URL) async -> Book? {
        isImporting = true
        defer { isImporting = false }

        let ext = sourceURL.pathExtension.lowercased()
        let format: BookFormat?
        switch ext {
        case "epub": format = .epub
        case "pdf": format = .pdf
        // Audiobooks: M4B/M4A are mpeg4 containers, and an MP3 with ID3 CHAP
        // frames is the other one that carries chapters. Anything else is not
        // a book.
        case "m4b", "m4a", "mp4", "mp3": format = .audio
        // Office documents normalize to EPUB at import (DocumentEpub): the
        // reader, the TOC and the TTS spine pipeline all consume the result
        // unchanged, so downstream nothing ever knows the difference.
        case "docx", "odt": format = .epub
        default:
            format = nil
        }
        guard let format else {
            importError = "Unsupported book format: .\(ext)"
            return nil
        }

        let id = UUID()
        let dir = Self.bookDirectory(id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Audio books keep their TRUE extension (original.m4b, not
            // original.audio): AVURLAsset maps a URL to its container parser
            // largely by extension, and a file named .audio made every
            // metadata/chapter/cover read come back empty (while AVAudioPlayer,
            // which sniffs content, kept playing fine — hiding the damage).
            let destinationExtension = format == .audio ? ext : format.rawValue
            let destination = dir.appendingPathComponent("original.\(destinationExtension)")
            if ext == "docx" || ext == "odt" {
                // Normalize-to-EPUB: parse the office XML into chapters and
                // emit a real EPUB the reader + TTS pipeline already speak.
                do {
                    let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                    let chapters = try (ext == "docx"
                        ? DocxParser.parse(archive: sourceData)
                        : OdtParser.parse(archive: sourceData))
                    let title = (sourceURL.lastPathComponent as NSString).deletingPathExtension
                        .replacingOccurrences(of: "_", with: " ")
                    let epub = DocumentEpubConverter.epubData(chapters: chapters, title: title, author: nil)
                    try epub.write(to: destination, options: .atomic)
                } catch {
                    importError = "Could not read the \(ext.uppercased()) document: \(error.localizedDescription)"
                    try? FileManager.default.removeItem(at: dir)
                    return nil
                }
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }
        } catch {
            importError = "Could not copy \"\(sourceURL.lastPathComponent)\": \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: dir)
            return nil
        }

        let fileName = sourceURL.lastPathComponent
        let parsed = await Task.detached(priority: .userInitiated) { () -> Book in
            Self.buildManifest(id: id, format: format, originalFileName: fileName, directory: dir)
        }.value

        do {
            let data = try JSONEncoder().encode(parsed)
            try data.write(to: Self.manifestURL(id), options: .atomic)
        } catch {
            importError = "Could not save book metadata: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        refresh()
        return parsed
    }

    /// Runs off-main. Reads only a few zip entries (epub) or the lazy
    /// PDFDocument attributes — never the whole book into memory.
    nonisolated private static func buildManifest(id: UUID, format: BookFormat, originalFileName: String, directory: URL) -> Book {
        let fallbackTitle = (originalFileName as NSString)
            .deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
        var book = Book(
            id: id,
            title: fallbackTitle,
            format: format,
            originalFileName: originalFileName
        )

        switch format {
        case .epub:
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("original.epub"), options: .mappedIfSafe) else {
                book.importError = "The EPUB file could not be read."
                return book
            }
            let info: EpubInfo
            do {
                info = try EpubParser.parse(archive: data)
            } catch let ZipReader.ZipError.encryptedEntry(name) {
                book.importError = "DRM-protected (encrypted \(name)) — can't be read aloud."
                return book
            } catch {
                book.importError = "This EPUB is malformed — chapters and speech may be unavailable."
                return book
            }
            book.title = info.title?.isEmpty == false ? info.title! : fallbackTitle
            book.author = info.creator?.isEmpty == false ? info.creator : nil
            book.spineCount = info.spine.isEmpty ? nil : info.spine.count
            // The TTS pipeline reads chapters straight from the archive with
            // these paths — no webview needed for speech.
            book.spine = info.spine.isEmpty ? nil : info.spine
            if let coverPath = info.coverPath,
               let coverData = try? ZipReader.readEntry(coverPath, in: data),
               !coverData.isEmpty {
                try? coverData.write(to: directory.appendingPathComponent("cover.jpg"), options: .atomic)
                book.hasCover = true
            }
            // Snapshot the TOC with spine indices so the reader can navigate
            // without a webview. Anchors whose href missed the spine are kept
            // but unlinked.
            if !info.toc.isEmpty {
                let indexByHref = Dictionary(info.spine.enumerated().map { ($1, $0) },
                                             uniquingKeysWith: { first, _ in first })
                book.toc = info.toc.map { entry in
                    BookTocEntry(label: entry.label, href: entry.href, spineIndex: indexByHref[entry.href])
                }
            }
        case .pdf:
            // The copy is local, so PDFDocument(url:) stays lazy — no whole
            // PDF load just to read the title (ImportService's whole-doc
            // string extraction is the pattern we are deliberately avoiding).
            if let document = PDFDocument(url: directory.appendingPathComponent("original.pdf")) {
                if document.isLocked {
                    book.importError = "Password-protected PDF — can't be read aloud."
                    return book
                }
                book.pageCount = document.pageCount > 0 ? document.pageCount : nil
                // documentAttributes bridges as [AnyHashable: Any] — key it
                // with the full PDFDocumentAttribute spelling.
                let attrs = document.documentAttributes
                if let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { book.title = title }
                if let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { book.author = author }
                // Chapters = the PDF's own outline when it has one, heading
                // detection when it doesn't, labeled page ranges as the
                // floor. Resolved once here, stored in the manifest.
                let resolved = PdfText.resolveChapters(in: document)
                if !resolved.chapters.isEmpty {
                    book.pdfChapters = resolved.chapters
                    book.pdfChapterSource = resolved.source
                }
                // Cover = page 1 rendered to a JPEG (epubs carry their real
                // cover; without this PDFs show a generic glyph on the shelf).
                if let page = document.page(at: 0) {
                    if let data = Self.renderPDFCover(page: page) {
                        try? data.write(to: directory.appendingPathComponent("cover.jpg"), options: .atomic)
                        book.hasCover = true
                    }
                }
            }
        case .audio:
            book = Self.buildAudioManifest(book: book, directory: directory)
        }
        return book
    }

    /// Chapters through AVFoundation's own reader. `timeRange` carries each
    /// chapter's start AND duration, so ends are real, and the title comes
    /// from the group's metadata. Empty (not an error) when the file carries
    /// no chapter metadata AVFoundation understands.
    nonisolated private static func chaptersFromAVFoundation(_ asset: AVURLAsset, totalSeconds: Double) -> [AudioChapter] {
        // The sync accessor blocks until the metadata is loaded — exactly the
        // awaited semantics the metadata read below needs, on a thread that
        // may block (the detached manifest builder).
        let groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        guard !groups.isEmpty else { return [] }
        var chapters: [AudioChapter] = []
        for group in groups {
            let start = group.timeRange.start.seconds
            let end = group.timeRange.end.seconds
            let title = group.items.first(where: { $0.commonKey == .commonKeyTitle })?.stringValue ?? ""
            guard start.isFinite, start >= 0, end.isFinite, end >= start else { continue }
            chapters.append(AudioChapter(title: title, startSeconds: start, endSeconds: end))
        }
        guard let normalized = AudiobookChapters.normalize(chapters, totalSeconds: totalSeconds), !normalized.isEmpty else {
            return []
        }
        return normalized
    }

    /// Reads what an audiobook file says about itself: title/author from the
    /// tags, duration from the audio file, and the chapter list from the
    /// container's own metadata. All off-main (the caller detaches) and all
    /// bounded — a chapter list is small by definition and the duration comes
    /// from AVURLAsset, which reads the header rather than the samples.
    nonisolated private static func buildAudioManifest(book: Book, directory: URL) -> Book {
        var book = book
        let original = resolveAudioOriginalURL(book: book)
        let asset = AVURLAsset(url: original, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        // Same awaited-load discipline as the metadata read below: the sync
        // `asset.duration` raced the async property load on device and could
        // come back 0 for files that play for hours (the last chapter then
        // ended at start+1s — one more contributor to "it stops after two
        // seconds").
        let durationSem = DispatchSemaphore(value: 0)
        final class Box { var value: CMTime = .invalid }
        let box = Box()
        Task.detached {
            if let duration = try? await asset.load(.duration) {
                box.value = duration
            }
            durationSem.signal()
        }
        _ = durationSem.wait(timeout: .now() + 5)
        let seconds = box.value.isValid ? box.value.seconds : asset.duration.seconds
        if seconds.isFinite, seconds > 0 { book.audioDuration = seconds }

        // Chapters, in order of trust:
        //   1. AVFoundation's own chapter reader — it understands chpl atoms
        //      AND QuickTime chapter tracks (the m4b-tool/ffmpeg form the
        //      hand parser needs a full sample-table walk for) and resolves
        //      titles. The first device round showed the byte parsers alone
        //      leave real books with "Full audiobook" as the only chapter.
        //   2. The hand parsers — the fallback for files AVFoundation opens
        //      without chapter metadata, and the unit-tested reference.
        //
        // Only an 8 MB head slice and (at most) one 8 MB tail slice are
        // read now — never the whole file. moov lives at the head
        // (+faststart) or the tail (plain ffmpeg) and nothing between is
        // a box header. Mapping a 266 MB m4b — let alone a 1.5 GB
        // Harrisons-sized one — to find a box that is at one end or the
        // other is the device freeze: every page of the map is a fault,
        // the utility queue competes with the main thread for I/O, and
        // taps stop landing.
        let avChapters = Self.chaptersFromAVFoundation(asset, totalSeconds: book.audioDuration ?? 0)
        if !avChapters.isEmpty {
            book.audioChapters = avChapters
            book.audioChapterSource = "avfoundation"
        }

        if book.audioChapters == nil {
            let chapters: [AudioChapter]
            if book.format == .audio, let head = Self.slice(of: original, from: 0, length: Self.audioParseHeadBytes) {
                if head.starts(with: [0x49, 0x44, 0x33]) {
                    // MP3: ID3v2 lives at the head, full stop.
                    chapters = AudiobookChapters.chaptersFromID3(head)
                } else {
                    // MP4-family: the HEAD slice starts on a box boundary
                    // so the normal box walk reads moov when the file was
                    // written +faststart. Otherwise moov lives at the end
                    // and the tail slice starts MID-mdat — no box walk
                    // works there, so chaptersFromMP4Tail hunts chpl by
                    // signature (its own count + title lengths validate
                    // the hit; a random 4CC in audio payload fails the
                    // parse and the scan moves on).
                    var found = AudiobookChapters.chaptersFromMP4(head, totalSeconds: book.audioDuration ?? 0)
                    if found.isEmpty {
                        let size = Self.fileSize(of: original)              // Int64
                        let tailStart = max(0, size - Int64(Self.audioParseTailBytes))
                        if let tail = Self.slice(of: original, from: tailStart, length: Self.audioParseTailBytes) {
                            found = AudiobookChapters.chaptersFromMP4Tail(tail, totalSeconds: book.audioDuration ?? 0)
                        }
                    }
                    chapters = found
                }
            } else {
                chapters = []
            }
            if !chapters.isEmpty {
                book.audioChapters = chapters
                book.audioChapterSource = "mp4-full"
            }
        }

        // No chapter metadata: the whole file is one chapter so the player bar
        // has a unit and the position can still be remembered. `single` is the
        // marker the shelf backfill looks for — a book that only ever got ONE
        // chapter may simply pre-date the readers above, so it is re-read once.
        if book.audioChapters == nil {
            book.audioChapters = [AudioChapter(
                title: "Full audiobook",
                startSeconds: 0,
                endSeconds: book.audioDuration ?? 0
            )]
            book.audioChapterSource = "single"
        }

        // Tags: read the two common keys the shelf shows. `AVMetadataItem`
        // is created by asking the asset's metadata array for a key, not by
        // a static constructor — the asset loads its metadata lazily, so this
        // is a header read, not a whole-file scan.
        // Cover: MP4/M4B often embeds one. Without it the shelf shows the
        // format glyph, exactly as a cover-less PDF does.
        //
        // The metadata read must go through `load(.metadata)` FIRST on a
        // background thread: `asset.metadata` returns [] until the status
        // becomes .loaded, and the sync getter raced that load on device —
        // titles, authors AND covers all came back empty for files that
        // plainly had them (the "no thumbnail" report; the title survived
        // only because the filename fallback covered it).
        let metadataSem = DispatchSemaphore(value: 0)
        final class MetaBox { var value: [AVMetadataItem] = [] }
        let metaBox = MetaBox()
        Task.detached {
            if let items = try? await asset.load(.metadata) {
                metaBox.value = items
            }
            metadataSem.signal()
        }
        _ = metadataSem.wait(timeout: .now() + 5)
        let metadata = metaBox.value.isEmpty ? asset.metadata : metaBox.value

        let title = Self.metadataString(metadata, key: AVMetadataKey.commonKeyTitle.rawValue)
        if let title, !title.isEmpty { book.title = title }
        let artist = Self.metadataString(metadata, key: AVMetadataKey.commonKeyArtist.rawValue)
        if let artist, !artist.isEmpty { book.author = artist }
        if let artwork = Self.metadataData(metadata, key: AVMetadataKey.commonKeyArtwork.rawValue),
           !artwork.isEmpty,
           let image = UIImage(data: artwork),
           let jpeg = image.jpegData(compressionQuality: 0.85) {
            // Re-encode through UIImage: some M4B covers are PNG or odd-size
            // HEIC payloads that a raw `.write` stores with a .jpg name the
            // shelf's UIImage(data:) still decodes, but the FILES app and
            // QuickLook reject. One normalized JPEG, always decodable.
            try? jpeg.write(to: directory.appendingPathComponent("cover.jpg"), options: [.atomic])
            book.hasCover = true
        }

        // One line that says what the file actually gave us — the device
        // round reports ("no thumbnail, no chapters") are unreadable without
        // knowing which of the three readers fired and what they found.
        Log.shared.info(
            "AudioBook import: «\(book.title)» \(String(format: "%.1f", book.audioDuration ?? -1))s, " +
            "\(book.audioChapters?.count ?? 0) chapter(s) via \(book.audioChapterSource ?? "?"), " +
            "cover \(book.hasCover ? "found" : "none"), author \(book.author ?? "-")"
        )
        return book
    }

    /// One common metadata key as a string, or nil. Tolerant by design: an
    /// unreadable or missing tag is not an import failure.
    nonisolated private static func metadataString(_ items: [AVMetadataItem], key: String) -> String? {
        guard let item = items.first(where: { $0.commonKey?.rawValue == key }) else { return nil }
        return item.stringValue
    }

    /// One common metadata key as data (the artwork path), or nil.
    nonisolated private static func metadataData(_ items: [AVMetadataItem], key: String) -> Data? {
        guard let item = items.first(where: { $0.commonKey?.rawValue == key }) else { return nil }
        return item.dataValue
    }

    /// Renders one PDF page as a shelf-cover JPEG. Width-fixed (600 pt),
    /// height follows the page's own aspect ratio.
    nonisolated private static func renderPDFCover(page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .cropBox)
        let width: CGFloat = 600
        let height = bounds.height > 0 ? width * bounds.height / bounds.width : width
        let thumbnail = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        return thumbnail.jpegData(compressionQuality: 0.85)
    }

    // MARK: - Mutations

    /// Soft-deletes into the recycle bin (notes' pattern): the file stays on
    /// disk for `Book.recycleRetentionDays`, so a mis-tap on a 3 GB
    /// audiobook is recoverable. purge() is the one real removal.
    func delete(_ book: Book) {
        guard let idx = allBooks.firstIndex(where: { $0.id == book.id }) else { return }
        var binned = book
        binned.deletedAt = Date()
        allBooks[idx] = binned
        books.removeAll { $0.id == book.id }
        save(binned)
        if book.format == .audio {
            NotificationCenter.default.post(name: .audioBookStopped, object: book.id)
        }
    }

    /// Moves a binned book back onto the shelf, timestamp preserved.
    func recover(_ book: Book) {
        guard let idx = allBooks.firstIndex(where: { $0.id == book.id }) else { return }
        var restored = book
        restored.deletedAt = nil
        allBooks[idx] = restored
        books = allBooks.filter { !$0.isDeleted }.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
        save(restored)
    }

    /// Really deletes one binned book. No undo.
    func purge(_ book: Book) {
        try? FileManager.default.removeItem(at: Self.bookDirectory(book.id))
        allBooks.removeAll { $0.id == book.id }
        books.removeAll { $0.id == book.id }
    }

    /// Purges every binned book past the retention window — called on
    /// refresh (once per shelf open), like NotesStore's prune.
    private func pruneExpiredBooks() {
        let cutoff = Date().addingTimeInterval(-Double(Book.recycleRetentionDays) * 24 * 3600)
        let expired = allBooks.filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        guard !expired.isEmpty else { return }
        for book in expired {
            try? FileManager.default.removeItem(at: Self.bookDirectory(book.id))
        }
        allBooks.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
    }

    /// Really deletes every binned book.
    func emptyRecycleBin() {
        for book in allBooks where book.isDeleted {
            try? FileManager.default.removeItem(at: Self.bookDirectory(book.id))
        }
        allBooks.removeAll { $0.isDeleted }
    }

    /// Monotonic write counter per book — a detached encode-then-write can
    /// land AFTER a newer save (e.g. updatePosition fired again while the
    /// first encode was queued), and the stale manifest would win. Holding
    /// the newest sequence per book and dropping older writes at flush time
    /// keeps last-writer-wins instead of last-flush-wins (M18).
    private static let seqLock = NSLock()
    nonisolated(unsafe) private static var writeSeq: [UUID: Int] = [:]

    /// Saves a mutated book (position, lastOpenedAt) back to its manifest.
    /// Periodic position writes (AudioBookPlayer's 10 s ticker, the reader's
    /// scroll) call this often; save() re-derives nothing beyond the one
    /// book it's handed.
    func save(_ book: Book) {
        guard let idx = allBooks.firstIndex(where: { $0.id == book.id }) else { return }
        allBooks[idx] = book
        if !book.isDeleted,
           let activeIdx = books.firstIndex(where: { $0.id == book.id }) {
            books[activeIdx] = book
        }
        Self.seqLock.lock()
        let seq = (Self.writeSeq[book.id] ?? 0) + 1
        Self.writeSeq[book.id] = seq
        Self.seqLock.unlock()
        let snapshot = book
        Task.detached(priority: .utility) {
            // Persist ONLY this book's manifest — the old path encoded the
            // whole shelf (books are structs carried in memory here, so a
            // position write paid for every other book's JSON on every 10 s
            // tick). One small atomic write per call instead.
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            // A NEWER save() was already issued while this encode was in
            // flight — drop the stale write rather than overwrite with it.
            Self.seqLock.lock()
            let latest = Self.writeSeq[snapshot.id]
            Self.seqLock.unlock()
            guard latest == seq else { return }
            try? data.write(to: Self.manifestURL(snapshot.id), options: .atomic)
        }
    }

    func markOpened(_ book: Book) {
        var updated = book
        updated.lastOpenedAt = Date()
        updated.deletedAt = nil      // opening a binned book un-bins it
        save(updated)
    }

    func updatePosition(_ book: Book, chapterIndex: Int, chapterFraction: Double, cfi: String? = nil) {
        var updated = book
        updated.position = BookPosition(
            chapterIndex: chapterIndex,
            chapterFraction: chapterFraction,
            cfi: cfi
        )
        save(updated)
    }
}
