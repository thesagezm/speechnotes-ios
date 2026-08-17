import SwiftUI
import SpeechLogic

/// Block-rendered markdown reading view: real heading sizes, paragraph
/// spacing, list bullets, quotes and code blocks — and single line breaks
/// stay visible (notes semantics). Inline styling (bold/italic/code/links)
/// comes from Foundation's inline markdown parser, per block.
struct MarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(MarkdownText.blocks(markdown).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownText.MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 18 : 14)
                .padding(.bottom, 6)
        case .paragraph(let text):
            inlineText(text)
                .lineSpacing(4)
                .padding(.bottom, 14)
        case .bulletList(let items):
            listRows(items.map { ("•", $0) })
        case .orderedList(let items):
            listRows(items.enumerated().map { ("\($0.offset + 1).", $0.element) })
        case .quote(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.bottom, 14)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            )
            .padding(.bottom, 14)
        case .divider:
            Divider().padding(.vertical, 10)
        }
    }

    private func listRows(_ rows: [(marker: String, item: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.marker)
                        .foregroundStyle(.secondary)
                    inlineText(row.item).lineSpacing(3)
                }
            }
        }
        .padding(.bottom, 14)
    }

    /// Inline-only markdown parse — exactly what the default
    /// `AttributedString(markdown:)` does; on any parse failure the raw
    /// string shows verbatim.
    private func inlineText(_ string: String) -> Text {
        if let parsed = try? AttributedString(markdown: string) {
            return Text(parsed)
        }
        return Text(string)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        case 4: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}
