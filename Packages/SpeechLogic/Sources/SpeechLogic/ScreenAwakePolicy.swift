//
//  ScreenAwakePolicy.swift
//  SpeechLogic
//
//  The decision behind the "Keep Screen On" setting: whether the device's
//  idle timer — the one that dims and then locks the screen — is allowed
//  to run while the user reads.
//
//  Pure and assertable in CI, which is the only reason it lives in
//  SpeechLogic (the app target has no test target). The UIApplication side
//  lives in App/Sources/Services/ScreenAwake.swift and cannot be tested
//  without a device.
//

import Foundation

/// The surfaces that can hold the screen awake, one per place the user
/// actually reads.
///
/// A SET of these — not a counter, not a bare boolean — is what makes the
/// app-wide decision correct: a tab switch releases the outgoing surface
/// and acquires the incoming one in an order SwiftUI does not guarantee,
/// and only set membership makes the answer independent of that order.
public enum ScreenAwakeSurface: String, CaseIterable, Equatable, Sendable {
    case epubReader
    case pdfReader
    case audiobookReader
    case noteReader
}

public enum ScreenAwakePolicy {

    /// The `UserDefaults` key the setting lives under. One constant shared
    /// by the toggle, the controller and the tests — a key that drifted
    /// between the two would be exactly the "toggle that silently does
    /// nothing" bug.
    public static let preferenceKey = "keepScreenOn"

    /// ON by default. The setting exists because a screen that dims
    /// mid-book loses the reader's place — the mainstream reader apps
    /// (Kindle, Apple Books) hold the screen awake while reading for the
    /// same reason. The hold only applies while a reading surface is on
    /// screen, so the battery cost is bounded to actual reading; a user
    /// who dislikes it flips one toggle.
    public static let defaultEnabled = true

    /// Whether the note editor counts as a READING surface right now.
    ///
    /// THE SCOPE DECISION for the whole setting, written down where it can
    /// be tested: the editor is reading in preview and in read-along, and
    /// is TYPING in edit mode. Editing needs no hold — the software
    /// keyboard already keeps the screen awake — so the setting applies
    /// there silently-by-doing-nothing rather than pinning the screen on
    /// behind a keyboard.
    public static func noteIsReadingSurface(
        renderMarkdown: Bool,
        showPreview: Bool,
        readAlongShowing: Bool
    ) -> Bool {
        readAlongShowing || (renderMarkdown && showPreview)
    }

    /// The whole decision. Zero surfaces must always yield `false` — that
    /// is the "leaving the reader hands the screen back to the system
    /// timer" invariant the device round checks, and it is why the
    /// preference alone is never enough.
    public static func shouldKeepScreenAwake(
        preferenceEnabled: Bool,
        activeSurfaces: Set<ScreenAwakeSurface>
    ) -> Bool {
        preferenceEnabled && !activeSurfaces.isEmpty
    }
}
