import SwiftUI
import UIKit
/// UIKit-backed markdown editor that reports live selection + caret position.
///
/// SwiftUI's `TextEditor` on iOS 18 does not surface selection changes, which
/// is why the markdown formatting bar (bold / italic / bullet / ...) silently
/// operated at end-of-text. `UITextView` reports both `text` and `selection`
/// via its delegate — Joplin's mobile editor uses the same `onSelectionChange`
/// pattern (just React Native's wrapper around UITextView).
struct MarkdownEditorView: UIViewRepresentable {
    @Binding var text: String
    /// Live selection as a UTF-16 offset range. Drives the formatting bar.
    @Binding var selection: Range<Int>?
    /// Caret moved — used by the slash-menu detector to re-scan for `/`.
    var onCaretMoved: (() -> Void)?
    /// Focus relay so the SwiftUI toolbar can claim/reclaim focus.
    var focusState: FocusState<Bool>.Binding
    /// User-selected reading size, forwarded to the UITextView's font so the
    /// edit buffer matches the preview scale.
    var textScale: CGFloat = 1.0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.keyboardDismissMode = .interactive
        // Gutter inside the text container so text doesn't sit at the very
        // edge of the screen. lineFragmentPadding is the per-line horizontal
        // gutter (UIKit default is 5pt); textContainerInset is the outer
        // padding around the whole text area.
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.textContainer.lineFragmentPadding = 5
        tv.adjustsFontForContentSizeCategory = true
        let font = Self.editorFont(scale: textScale)
        tv.font = font
        tv.text = text
        tv.isUserInteractionEnabled = true
        context.coordinator.lastSentText = text
        context.coordinator.lastAppliedFontSize = font.pointSize
        return tv
    }

    /// Editor font follows the reading-size setting scaled onto the system
    /// body size — matches MarkdownPreviewView so edit ↔ preview doesn't jump.
    static func editorFont(scale: CGFloat) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: .body).pointSize
        return UIFont.systemFont(ofSize: base * scale)
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Only push `text` into the UITextView when it DIFFERS from what we
        // last sent — overwriting the editor mid-keystroke resets the caret
        // and the first responder, which made the old TextEditor wrapper
        // fight SwiftUI. UITextView already tracks its own edits, so this
        // path fires only on programmatic changes (format-bar wrap, paste).
        if uiView.text != text, context.coordinator.lastSentText != text {
            let preserved = uiView.selectedRange
            uiView.text = text
            uiView.selectedRange = preserved
            context.coordinator.lastSentText = text
        }
        // Only touch the font when the size actually changed — assigning the
        // font rebuilds text storage, drops typing attributes, and can kill
        // an active selection mid-gesture.
        let wanted = Self.editorFont(scale: textScale)
        if wanted.pointSize != context.coordinator.lastAppliedFontSize {
            uiView.font = wanted
            context.coordinator.lastAppliedFontSize = wanted.pointSize
        }
        if focusState.wrappedValue && !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !focusState.wrappedValue && uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: MarkdownEditorView
        /// Tracks the last value we pushed *into* UITextView from SwiftUI
        /// so we can skip redundant writes that would clobber the caret.
        var lastSentText: String = ""
        var lastAppliedFontSize: CGFloat = 0
        init(_ parent: MarkdownEditorView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            reportSelection(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            reportSelection(textView)
            parent.onCaretMoved?()
        }

        private func reportSelection(_ textView: UITextView) {
            let utf16 = textView.selectedRange
            // A zero-length selection is still a caret position — report it
            // so the formatting bar can insert at the caret instead of
            // defaulting to end-of-text. Skip redundant assignments: each
            // binding write re-renders the editor + formatting bar.
            let range = utf16.lowerBound..<utf16.upperBound
            if parent.selection != range {
                parent.selection = range
            }
        }
    }
}
