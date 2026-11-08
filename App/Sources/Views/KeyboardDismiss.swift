import SwiftUI
import UIKit

/// Tap-outside-dismisses-keyboard for the settings surfaces (and any Form
/// that hosts a text field).
///
/// Two halves:
///  - `.scrollDismissesKeyboard(.immediately)` on the Form/List — dragging
///    the list puts the keyboard away (native iOS 16+ behavior).
///  - This representable — the TAP-OUTSIDE half the platforms never gave
///    SwiftUI. A `UITapGestureRecognizer` is attached to the key WINDOW (a
///    recognizer on a background layer never sees touches: the Form
///    hit-tests them first), with `cancelsTouchesInView = false`, so it
///    only OBSERVES touches — rows, toggles, buttons and links act exactly
///    as they did.
///
/// The one guard that makes it safe: a tap that landed on a text control
/// does nothing — touching the field must FOCUS it, not instantly unfocus
/// it (the complaint that motivates this file is the opposite one: a field
/// that never lets go). The recognizer leaves the window when its hosting
/// view does, and because the guard is content-based, one left alive by a
/// kept-alive tab is still harmless elsewhere in the app.
struct KeyboardDismissOnTap: UIViewRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        // Passive host — the recognizer acts on the window, this view only
        // carries the lifecycle (and must not eat touches of its own).
        view.isUserInteractionEnabled = false
        let recognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        context.coordinator.recognizer = recognizer
        // The window does not exist yet inside makeUIView (the view is not
        // in the hierarchy); attach on the next runloop turn.
        DispatchQueue.main.async { [weak view, weak recognizer] in
            guard let view, let recognizer, recognizer.view == nil,
                  let window = view.window else { return }
            window.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // A lazily presented surface (a sheet) may still have been outside
        // the hierarchy for the make-time hop — attach now, guarded so the
        // call stays idempotent.
        if let recognizer = context.coordinator.recognizer,
           recognizer.view == nil,
           let window = uiView.window {
            window.addGestureRecognizer(recognizer)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let recognizer = coordinator.recognizer {
            uiView.window?.removeGestureRecognizer(recognizer)
        }
        coordinator.recognizer = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var recognizer: UITapGestureRecognizer?

        /// Resign whatever is first responder — unless the tap landed on a
        /// text control. Resigning when the keyboard is already down is a
        /// harmless no-op.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if let window = recognizer.view?.window,
               let hit = window.hitTest(recognizer.location(in: window), with: nil),
               Self.isTextControl(hit) {
                return
            }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }

        /// True when `view` (or an ancestor) is the text control being
        /// tapped into. The UIKit classes catch the plain fields; the
        /// class-name check catches the SwiftUI proxy/vertical-axis classes
        /// that do not subclass them. Erring TOWARD "this is a text field"
        /// is the safe direction: the cost of a false positive is one tap
        /// that does not dismiss the keyboard, while a false negative would
        /// make a field unfocus the moment the user taps into it.
        private static func isTextControl(_ view: UIView) -> Bool {
            var current: UIView? = view
            while let node = current {
                if node is UITextField || node is UITextView { return true }
                let name = NSStringFromClass(type(of: node))
                if name.contains("TextField")
                    || name.contains("TextView")
                    || name.contains("TextEditor") {
                    return true
                }
                current = node.superview
            }
            return false
        }

        /// Never blocks anything: scroll gestures, control presses and the
        /// fields' own recognizers all run alongside.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

extension View {
    /// Tap anywhere outside a text field in this subtree and the keyboard
    /// goes down. Pair with `.scrollDismissesKeyboard(.immediately)` on the
    /// Form/List for the scroll half.
    func dismissesKeyboardOnTapOutside() -> some View {
        background(KeyboardDismissOnTap())
    }
}
