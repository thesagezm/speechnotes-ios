import re
p = "App/Sources/Services/SpeechPlayer.swift"
s = open(p).read()

# snapResume: add pieces
old = """    private static func snapResume(mark: PlaybackBookmark, fullText: String) -> (offset: Int, suffix: String)? {
        let length = fullText.utf16.count
        let offset = Self.resumeOffset(in: fullText, charsDone: mark.charsDone)
        guard offset > 0, offset < length else { return nil }
        let units = Array(fullText.utf16)
        let suffix = String(decoding: Array(units[offset...]), as: UTF16.self)
        guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (offset, suffix)
    }"""
new = """    private static func snapResume(mark: PlaybackBookmark, fullText: String) -> (offset: Int, suffix: String, pieces: [(offset: Int, endOffset: Int)])? {
        let length = fullText.utf16.count
        let offset = Self.resumeOffset(in: fullText, charsDone: mark.charsDone)
        guard offset > 0, offset < length else { return nil }
        let units = Array(fullText.utf16)
        let suffix = String(decoding: Array(units[offset...]), as: UTF16.self)
        guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let pieces = SentenceChunker.sentencePieces(in: suffix)
            .map { (offset: $0.offset + offset, endOffset: $0.endOffset + offset) }
        return (offset, suffix, pieces)
    }"""
assert old in s
s = s.replace(old, new)

# note resume caller
old = """        return Self.snapResume(mark: mark, fullText: fullText)
    }

    /// Book variant: the bookmark must match this book AND chapter."""
new = """        guard let plan = Self.snapResume(mark: mark, fullText: fullText) else { return nil }
        return (plan.offset, plan.suffix, plan.pieces)
    }

    /// Book variant: the bookmark must match this book AND chapter."""
assert old in s
s = s.replace(old, new)

# book resume caller
old = """        return Self.snapResume(mark: mark, fullText: fullText)
    }

    /// True when the editor should show "Restart from beginning"."""
new = """        guard let plan = Self.snapResume(mark: mark, fullText: fullText) else { return nil }
        return (plan.offset, plan.suffix, plan.pieces)
    }

    /// True when the editor should show "Restart from beginning"."""
assert old in s
s = s.replace(old, new)

# beginReadAlong gains pieces param
old = """    private func beginReadAlong(fullText: String) {
        activeSpeechText = fullText
        readAlongRange = nil
        readAlongPieces = []
        readAlongPiecesTask?.cancel()
        let generation = readAlongGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let pieces = SentenceChunker.sentencePieces(in: fullText)
            await MainActor.run {
                guard let self,
                      self.readAlongGeneration == generation,
                      self.activeSpeechText == fullText else { return }
                self.readAlongPieces = pieces
            }
        }
    }"""
new = """    private func beginReadAlong(fullText: String, pieces: [(offset: Int, endOffset: Int)]? = nil) {
        activeSpeechText = fullText
        readAlongRange = nil
        readAlongPieces = []
        readAlongPiecesTask?.cancel()
        if let pieces {
            readAlongPieces = pieces
            return
        }
        let generation = readAlongGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let pieces = SentenceChunker.sentencePieces(in: fullText)
            await MainActor.run {
                guard let self,
                      self.readAlongGeneration == generation,
                      self.activeSpeechText == fullText else { return }
                self.readAlongPieces = pieces
            }
        }
    }"""
assert old in s
s = s.replace(old, new)

# note resume speak: insert beginReadAlong before engine?.speak
old = """                    engineSpeechOffset = plan.offset + Self.leadingWhitespaceUTF16(plan.suffix)
                    Log.shared.info("SpeechPlayer: resuming note at char \(plan.offset)/\(text.utf16.count)")
                    engine?.speak(plan.suffix, rateMultiplier: rateMultiplier)
                    return"""
new = """                    engineSpeechOffset = plan.offset + Self.leadingWhitespaceUTF16(plan.suffix)
                    beginReadAlong(fullText: text, pieces: plan.pieces)
                    Log.shared.info("SpeechPlayer: resuming note at char \(plan.offset)/\(text.utf16.count)")
                    engine?.speak(plan.suffix, rateMultiplier: rateMultiplier)
                    return"""
assert old in s
s = s.replace(old, new)

# book resume speak
old = """                    engineSpeechOffset = plan.offset + Self.leadingWhitespaceUTF16(plan.suffix)
                    Log.shared.info("SpeechPlayer: resuming book \(book.id) ch\(book.chapterIndex) at char \(plan.offset)/\(text.utf16.count)")
                    engine?.speak(plan.suffix, rateMultiplier: rateMultiplier)
                    return"""
new = """                    engineSpeechOffset = plan.offset + Self.leadingWhitespaceUTF16(plan.suffix)
                    beginReadAlong(fullText: text, pieces: plan.pieces)
                    Log.shared.info("SpeechPlayer: resuming book \(book.id) ch\(book.chapterIndex) at char \(plan.offset)/\(text.utf16.count)")
                    engine?.speak(plan.suffix, rateMultiplier: rateMultiplier)
                    return"""
assert old in s
s = s.replace(old, new)

open(p, "w").write(s)
print("P22 ok")
