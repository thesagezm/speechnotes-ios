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
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.keyboardDismissMode = .interactive
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = true
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.text = text
        tv.isUserInteractionEnabled = true
        context.coordinator.lastSentText = text
        return tv
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
        uiView.font = UIFont.preferredFont(forTextStyle: .body)
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
            // defaulting to end-of-text.
            parent.selection = utf16.lowerBound..<utf16.upperBound
        }
    }
}
