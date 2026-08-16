import SwiftUI
import UIKit

/// Read-only text view that highlights whatever range the speech engine is
/// currently speaking (read-along mode).
///
/// Performance contract: the base attributed string is built exactly once per
/// text (or appearance-input) change; every highlight move performs only two
/// ranged edits on the text view's `NSTextStorage` — restore base attributes
/// over the previous range, decorate the new range — so an update costs
/// O(changed range), never O(document). `NSTextStorage` relayouts only the
/// edited ranges, keeping multi-thousand-word notes jank-free.
struct ReadAlongTextView: UIViewRepresentable {
    /// Full text to display. `spokenRange` must already be expressed in this
    /// string's UTF-16 coordinates — the caller shifts from the trimmed text
    /// the engine was handed.
    let text: String
    /// UTF-16 range (into `text`) currently being spoken; nil = no highlight.
    let spokenRange: Range<Int>?
    /// UIKit-free appearance inputs so SwiftUI callers never touch UIColor
    /// or UIFont (both defaulted — `ReadAlongTextView(text:spokenRange:)`
    /// is enough).
    var textColor: Color = .primary
    var fontSize: CGFloat = 17

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.showsVerticalScrollIndicator = true
        textView.contentInsetAdjustmentBehavior = .automatic
        // 8pt per-line side padding, mirroring the editor's horizontal padding.
        textView.textContainer.lineFragmentPadding = 8

        context.coordinator.install(
            text: text,
            attributes: baseAttributes,
            appearanceInputs: appearanceInputs,
            in: textView
        )
        context.coordinator.applyHighlight(spokenRange, in: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        // Rebuild only when the text (hash) or appearance inputs changed —
        // plain SwiftUI re-renders must not touch the attributed string.
        if coordinator.textHash != text.hashValue
            || coordinator.currentAppearanceInputs != appearanceInputs {
            coordinator.install(
                text: text,
                attributes: baseAttributes,
                appearanceInputs: appearanceInputs,
                in: uiView
            )
        }
        coordinator.applyHighlight(spokenRange, in: uiView)
    }

    // MARK: - Private

    /// Identity of the SwiftUI-side appearance inputs; compared each render
    /// so font/color changes rebuild, and everything else doesn't.
    private var appearanceInputs: AppearanceInputs {
        AppearanceInputs(color: textColor, size: fontSize)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFontMetrics(forTextStyle: .body)
                .scaledFont(for: .systemFont(ofSize: fontSize)),
            .foregroundColor: UIColor(textColor),
        ]
    }

    struct AppearanceInputs: Equatable {
        let color: Color
        let size: CGFloat
    }

    // MARK: - Coordinator

    final class Coordinator {
        var textHash = -1
        var currentAppearanceInputs: ReadAlongTextView.AppearanceInputs?

        /// UTF-16 range currently carrying the highlight
        /// (location == NSNotFound when nothing is highlighted).
        private var lastAppliedRange = NSRange(location: NSNotFound, length: 0)
        private var baseAttributes: [NSAttributedString.Key: Any] = [:]

        private static let highlightAttributes: [NSAttributedString.Key: Any] = [
            .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.35),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: UIColor.systemOrange,
        ]

        /// Installs a fresh, unhighlighted attributed string. Called only
        /// when the text or appearance inputs change — never for highlight
        /// moves.
        func install(
            text: String,
            attributes: [NSAttributedString.Key: Any],
            appearanceInputs: ReadAlongTextView.AppearanceInputs,
            in textView: UITextView
        ) {
            currentAppearanceInputs = appearanceInputs
            baseAttributes = attributes
            textHash = text.hashValue
            lastAppliedRange = NSRange(location: NSNotFound, length: 0)
            textView.attributedText = NSAttributedString(string: text, attributes: attributes)
        }

        /// Moves the highlight to `range` with exactly two ranged edits on
        /// the text storage (guarded no-op when the range is unchanged, out
        /// of bounds, or nil). Sentence-chunk granularity means this runs
        /// roughly once per sentence — cheap enough to scroll every time.
        func applyHighlight(_ range: Range<Int>?, in textView: UITextView) {
            let limit = textView.textStorage.length
            let newRange: NSRange
            if let range, range.lowerBound >= 0, range.upperBound <= limit {
                newRange = NSRange(
                    location: range.lowerBound,
                    length: range.upperBound - range.lowerBound
                )
            } else {
                newRange = NSRange(location: NSNotFound, length: 0)
            }
            guard newRange != lastAppliedRange else { return }

            let storage = textView.textStorage
            storage.beginEditing()
            // Edit 1 — restore the base style over the previous highlight.
            if lastAppliedRange.location != NSNotFound, lastAppliedRange.length > 0 {
                storage.setAttributes(baseAttributes, range: lastAppliedRange)
            }
            // Edit 2 — decorate the newly spoken range.
            if newRange.location != NSNotFound, newRange.length > 0 {
                storage.addAttributes(Self.highlightAttributes, range: newRange)
            }
            storage.endEditing()

            lastAppliedRange = newRange
            if newRange.location != NSNotFound, newRange.length > 0 {
                textView.scrollRangeToVisible(newRange)
            }
        }
    }
}
