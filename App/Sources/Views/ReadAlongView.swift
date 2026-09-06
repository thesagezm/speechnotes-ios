import SwiftUI
import SpeechLogic

/// Dedicated read-along surface shown while a note is being spoken: renders
/// the EXACT text the engine is reading (`SpeechPlayer.activeSpeechText`)
/// with the currently-sounding sentence highlighted.
///
/// Why it looks like this: the v0.5 read-along (1) highlighted at buffer
/// SCHEDULE time — up to 3 chunks ahead of the audio, (2) at chunk rather
/// than sentence granularity, and (3) mapped engine coordinates onto the
/// markdown editor's text, where any transform mismatch drifted. This view
/// fixes all three: the position comes from the engine's play-time signal
/// (`onPlayedChars`), it is snapped to sentence boundaries via
/// SentenceChunker, and the rendered text IS the spoken text.
struct ReadAlongView: View {
    let text: String
    /// UTF-16 range in `text` of the sentence currently sounding.
    let activeRange: Range<Int>?
    let textScale: CGFloat

    @EnvironmentObject private var theme: AppTheme

    /// One paragraph per `\n`-separated block, tracking its UTF-16 start so
    /// a global highlight range can be projected into it. Paragraphs double
    /// as scroll anchors.
    private struct Paragraph: Identifiable {
        let id: Int
        let start: Int
        let content: Substring

        var end: Int { start + content.utf16.count }
    }

    private var paragraphs: [Paragraph] {
        var result: [Paragraph] = []
        var start = 0
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            result.append(Paragraph(id: index, start: start, content: line))
            start += line.utf16.count + 1 // +1 for the \n
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs) { paragraph in
                        Text(attributed(paragraph))
                            .font(.system(size: UIFont.preferredFont(forTextStyle: .body).pointSize * textScale))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(paragraph.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: activeRange?.lowerBound) { start in
                guard let start else { return }
                // Scroll the paragraph containing the highlight to center.
                if let paragraph = paragraphs.last(where: { start >= $0.start && start < $0.end }),
                   paragraph.id != paragraphs.first?.id {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(paragraph.id, anchor: .center)
                    }
                }
            }
        }
        .background(theme.colorScheme == .dark ? Color.black : Color(.systemBackground))
    }

    /// Paragraph text with the overlapping part of the global highlight
    /// range tinted. Built as before + highlighted + after so the highlight
    /// needs no AttributedString index math (emoji-safe).
    private func attributed(_ paragraph: Paragraph) -> AttributedString {
        var highlight = AttributedString()
        if let active = activeRange {
            let lower = max(active.lowerBound, paragraph.start)
            let upper = min(active.upperBound, paragraph.end)
            if lower < upper {
                let prefixOffset = lower - paragraph.start
                let length = upper - lower
                let units = Array(paragraph.content.utf16)
                let before = String(decoding: units[0..<prefixOffset], as: UTF16.self)
                let middle = String(decoding: units[prefixOffset..<(prefixOffset + length)], as: UTF16.self)
                var highlighted = AttributedString(middle)
                highlighted.backgroundColor = theme.accentColor.opacity(0.28)
                highlighted.foregroundColor = theme.colorScheme == .dark ? .white : .primary
                highlight = AttributedString(before) + highlighted
            }
        }
        if highlight.runs.isEmpty {
            return AttributedString(String(paragraph.content))
        }
        let afterOffset = (activeRange.map { min($0.upperBound, paragraph.end) - paragraph.start } ?? 0)
        let units = Array(paragraph.content.utf16)
        let after = String(decoding: units[min(afterOffset, units.count)...], as: UTF16.self)
        return highlight + AttributedString(after)
    }
}
