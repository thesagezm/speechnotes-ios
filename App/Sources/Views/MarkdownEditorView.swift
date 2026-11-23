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
    /// User-selected reading size, forwarded to the UITextView's font so the
    /// edit buffer matches the preview scale.
    var textScale: CGFloat = 1.0
    /// Whether "Play from selection" may appear in the built-in selection
    /// menu right now — UIKit asks this each time the menu builds, for the
    /// menu's OWN range (the loupe can move the selection after the last
    /// one the editor reported, so the reported range is not authoritative).
    /// The argument is the selection's start, as a UTF-16 offset into the
    /// editor's text.
    var canPlayFromSelection: ((Int) -> Bool)? = nil
    /// Performs the play — the menu item was tapped. The argument is the
    /// UTF-16 offset the play starts from.
    var onPlayFromSelection: ((Int) -> Void)? = nil

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
        // No bounce in the editor either — the user asked for the note to feel
        // static once open, and the editor is the same document. Scrolling
        // still works; it just stops dead at the ends instead of drifting.
        tv.alwaysBounceVertical = false
        tv.bounces = false
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
        // NOTE: the old path registered "Play from selection" through the
        // PROCESS-WIDE `UIMenuController.shared.menuItems`. That was the
        // regression that killed Copy in the notes (v1.8.2): assigning the
        // shared controller's items REPLACES the built-in edit menu for every
        // text view in the app — the legacy contract is "your list IS the
        // menu", not "your list is ADDED to the menu" — so Cut/Copy/Paste/
        // Select All vanished from the editor AND from SwiftUI's selectable
        // preview, while Books (a WKWebView with WebKit's own edit menu)
        // was untouched. The modern hook below APPENDS to the system's
        // suggested actions instead, so the built-in items always survive.
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
        // The coordinator holds the CURRENT view: the edit-menu hook asks it
        // whether playback may start, and that answer depends on live state
        // (player state, caret) the coordinator cannot see on its own.
        context.coordinator.parent = self
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
        // Focus is owned entirely by UIKit (taps make the UITextView first
        // responder). NEVER resign from here: a previous focus relay that
        // force-resigned whenever SwiftUI re-rendered broke typing (one
        // letter per tap) and destroyed long-press selections, because every
        // keystroke/selection change re-renders and re-entered updateUIView.
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// The CURRENT view. `var` (not `let`) because `updateUIView` hands
        /// the fresh struct over — the closures below read live SwiftUI
        /// state, and a coordinator frozen on the first render would ask a
        /// question about a world that no longer exists.
        var parent: MarkdownEditorView
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

        /// The modern edit-menu hook (iOS 16+): "Play from selection" is
        /// APPENDED to the menu the system suggests, so Cut / Copy / Paste /
        /// Select All / Look Up stay exactly where iOS puts them.
        ///
        /// The range handed over is the MENU'S OWN range — the loupe can
        /// move the selection after the editor last reported one, so the
        /// reported selection is not authoritative and the offset the play
        /// starts from must come from here.
        ///
        /// The default menu is returned (rebuilt from the suggested actions)
        /// whenever the custom item cannot be offered. Returning `nil` was
        /// the other option, but rebuilding from `suggestedActions` is
        /// exactly what the system does by default AND cannot be misread as
        /// "suppress the menu" — the one failure mode this whole round
        /// exists to undo.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let canPlay = parent.canPlayFromSelection,
                  let onPlay = parent.onPlayFromSelection,
                  canPlay(range.location) else {
                return UIMenu(title: "", children: suggestedActions)
            }
            let action = UIAction(
                title: String(localized: "Play from selection"),
                image: UIImage(systemName: "play.circle")
            ) { _ in
                onPlay(range.location)
            }
            return UIMenu(title: "", children: suggestedActions + [action])
        }
    }
}
