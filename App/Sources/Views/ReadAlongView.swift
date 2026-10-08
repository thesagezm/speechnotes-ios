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
///
/// Performance: the body re-evaluates on every sentence change (~1–2×/s)
/// during playback. Rows go through `.equatable()`, so SwiftUI re-renders
/// only the row whose content or highlighted subrange actually changed —
/// rebuilding every visible row's AttributedString per evaluation was the
/// "highlight can't keep up" jank (v1.4.2 BUG A).
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

    /// Cached paragraph split — computed once per text, never per render
    /// (body re-evaluates on every sentence change during playback; the
    /// old computed property re-split the whole note each time).
    @State private var paragraphs: [Paragraph] = []

    /// Row point size — computed once per body evaluation, not once per row.
    private var rowPointSize: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).pointSize * textScale
    }

    /// This view's own width — read from the probe below, recomputed every
    /// body evaluation so it can never go stale across a layout-only reflow
    /// (the rail minimize round trip resizes this scroll view without
    /// firing onChange in the same transaction).
    @State private var proxyWidth: CGFloat = 0
    /// Same probe, height half — "wide" is width > height, not a magic 500.
    @State private var proxyHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(width: 0, height: 0)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    proxyWidth = geo.size.width
                                    proxyHeight = geo.size.height
                                }
                                .onChange(of: geo.size.width) {
                                    proxyWidth = $0
                                    proxyHeight = geo.size.height
                                }
                        }
                    )
                LazyVStack(alignment: .leading, spacing: ReaderSpacing.readAlongRow * theme.readerBlockSpacing) {
                    ForEach(paragraphs) { paragraph in
                        ReadAlongRow(
                            content: String(paragraph.content),
                            highlight: localHighlight(in: paragraph),
                            pointSize: rowPointSize,
                            accent: theme.accentColor,
                            darkBackground: theme.colorScheme == .dark
                        )
                        .equatable()
                        .id(paragraph.id)
                    }
                }
                .padding(.leading, 16)
                // In landscape the trailing playback panel owns its documented
                // width (PlaybackRail.hostColumnWidth, which shrinks when the
                // rail is minimized) plus breathing room; the text column must
                // not run under it. Read from the scroll view's own geometry
                // so the inset is right on the very first frame of the new
                // orientation (an environment value can arrive a frame late —
                // the tab-rail bug).
                //
                // 2026-10-08: proxyWidth starts at 0 and only updates via
                // onAppear/onChange on the probe — a LAYOUT-ONLY reflow (the
                // rail minimize round trip) resizes the scroll view without
                // necessarily re-firing either hook in the same transaction,
                // so the inset ran one width stale and the text sat under
                // the rail's old column. A plain landscape test (width >
                // height) can't go stale: it is recomputed from the probe's
                // CURRENT size on every body evaluation, and the host (the
                // note editor's ZStack overlay arrangement) now pads the
                // column by the same hostColumnWidth the rail pins itself
                // with — the read-along no longer needs to guess the rail's
                // footprint at all, only to keep clear air on wide screens.
                .padding(.trailing, proxyWidth > proxyHeight ? 24 : 16)
            }
            .onChange(of: activeRange?.lowerBound) { start in
                guard let start else { return }
                // Scroll the paragraph containing the highlight to center —
                // only fires when the sentence changes, never per tick.
                if let paragraph = paragraphs.last(where: { start >= $0.start && start < $0.end }),
                   paragraph.id != paragraphs.first?.id {
                    proxy.scrollTo(paragraph.id, anchor: .center)
                }
            }
            .onAppear { rebuildParagraphs() }
            .onChange(of: text) { _ in rebuildParagraphs() }
        }
        // Static, like the note reader — scrolling works, the text stops dead
        // at the ends instead of drifting past them (user request).
        .scrollBounceBehavior(.basedOnSize, axes: [])
        .background(theme.colorScheme == .dark ? Color.black : Color(.systemBackground))
    }

    private func rebuildParagraphs() {
        var result: [Paragraph] = []
        var start = 0
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            result.append(Paragraph(id: index, start: start, content: line))
            start += line.utf16.count + 1 // +1 for the \n
        }
        paragraphs = result
    }

    /// Project the global active range into the paragraph's local UTF-16
    /// coordinates — nil when this paragraph isn't (partly) sounding.
    private func localHighlight(in paragraph: Paragraph) -> Range<Int>? {
        guard let active = activeRange else { return nil }
        let lower = max(active.lowerBound, paragraph.start)
        let upper = min(active.upperBound, paragraph.end)
        guard lower < upper else { return nil }
        return (lower - paragraph.start)..<(upper - paragraph.start)
    }
}

/// One paragraph row. Equatable on exactly the inputs that change its
/// pixels; `.equatable()` in the parent makes SwiftUI skip the body (and
/// the AttributedString rebuild) whenever nothing visible changed.
private struct ReadAlongRow: View, Equatable {
    let content: String
    /// UTF-16 subrange of `content` to tint — nil takes the plain fast path.
    let highlight: Range<Int>?
    let pointSize: CGFloat
    let accent: Color
    let darkBackground: Bool

    static func == (lhs: ReadAlongRow, rhs: ReadAlongRow) -> Bool {
        lhs.content == rhs.content
            && lhs.highlight == rhs.highlight
            && lhs.pointSize == rhs.pointSize
            && lhs.accent == rhs.accent
            && lhs.darkBackground == rhs.darkBackground
    }

    var body: some View {
        Group {
            if let highlight {
                Text(attributed(highlight))
            } else {
                Text(verbatim: content)
            }
        }
        .font(.system(size: pointSize))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// before + highlighted + after so the highlight needs no AttributedString
    /// index math (emoji-safe).
    private func attributed(_ highlight: Range<Int>) -> AttributedString {
        let units = Array(content.utf16)
        let before = String(decoding: units[0..<highlight.lowerBound], as: UTF16.self)
        let middle = String(decoding: units[highlight.lowerBound..<highlight.upperBound], as: UTF16.self)
        let after = String(decoding: units[highlight.upperBound...], as: UTF16.self)
        var highlighted = AttributedString(middle)
        highlighted.backgroundColor = accent.opacity(0.28)
        highlighted.foregroundColor = darkBackground ? .white : .primary
        return AttributedString(before) + highlighted + AttributedString(after)
    }
}
