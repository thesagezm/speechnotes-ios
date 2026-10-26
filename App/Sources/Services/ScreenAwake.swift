//
//  ScreenAwake.swift
//  Speechnotes
//
//  App-level owner of the iOS idle timer behind the "Keep Screen On"
//  setting (Settings → Reading).
//
//  `UIApplication.shared.isIdleTimerDisabled` is ONE GLOBAL flag, so the
//  reading surfaces must share one decision instead of each writing the
//  flag. The naive per-surface pattern — onAppear { flag = pref } /
//  onDisappear { flag = false } — is wrong in this app for a reason the
//  epub reader already documented: `onDisappear` fires on every TAB SWITCH
//  while the view stays alive in its tab's navigation stack. Two surfaces
//  can therefore be alive at once (a book in the Books stack, the editor
//  in the Notes stack), SwiftUI does not guarantee the outgoing surface's
//  disappear lands before the incoming one's appear, and with one global
//  flag the last writer wins — the screen dims while the user reads.
//
//  So surfaces REGISTER here instead of writing the flag, and the flag is
//  recomputed from the registered SET after every change. Set membership
//  makes the answer independent of callback order, and the arithmetic is
//  `ScreenAwakePolicy` in SpeechLogic — tested in CI, because this class
//  itself cannot be (no app test target, no device).
//
//  Main-thread only: every caller is a SwiftUI lifecycle callback or the
//  root scenePhase handler, and UIKit's idle timer is a main-thread
//  property. (Plain class, like PomodoroStore/WavPlayer — Swift 5
//  language mode, no Task hops on this path.)
//
import SwiftUI
import UIKit
import SpeechLogic

final class ScreenAwake {
    static let shared = ScreenAwake()

    /// The surfaces currently on screen. Insert/remove are idempotent, so
    /// SwiftUI firing `onAppear` twice without an intervening disappear
    /// (it can, across sheet/rotation churn) cannot drift the state.
    private var holders: Set<ScreenAwakeSurface> = []

    private init() {}

    /// The user's preference, read fresh on every apply — a toggle in
    /// Settings takes effect with no cached state to go stale (the
    /// `Haptics.enabled` pattern).
    private var preferenceEnabled: Bool {
        UserDefaults.standard.object(forKey: ScreenAwakePolicy.preferenceKey) as? Bool
            ?? ScreenAwakePolicy.defaultEnabled
    }

    func acquire(_ surface: ScreenAwakeSurface) {
        holders.insert(surface)
        apply()
    }

    func release(_ surface: ScreenAwakeSurface) {
        guard holders.remove(surface) != nil else { return }
        apply()
    }

    /// Re-applies the current decision — called when the preference
    /// changes and when the scene re-activates (iOS may reset the idle
    /// timer across a suspension; the holder set survives it, so one
    /// recompute restores the truth).
    func refresh() {
        apply()
    }

    private func apply() {
        let keepOn = ScreenAwakePolicy.shouldKeepScreenAwake(
            preferenceEnabled: preferenceEnabled,
            activeSurfaces: holders
        )
        // Defaults writes land here through refresh() on every change to
        // ANY key — only touch UIKit when the answer actually moved.
        guard UIApplication.shared.isIdleTimerDisabled != keepOn else { return }
        UIApplication.shared.isIdleTimerDisabled = keepOn
        Log.shared.info("ScreenAwake: screen \(keepOn ? "held on" : "released") — \(holders.map(\.rawValue).sorted().joined(separator: ", "))")
    }
}

// MARK: - View wiring

extension View {
    /// Keeps the screen awake while this surface is on screen, when the
    /// "Keep Screen On" setting is on.
    ///
    /// `isActive` lets a surface that is only SOMETIMES a reading surface
    /// (the note editor: preview/read-along vs editing) join and leave the
    /// hold without its view identity changing — flipping the flag swaps
    /// the hold, never the subtree.
    func keepScreenAwake(_ surface: ScreenAwakeSurface, isActive: Bool = true) -> some View {
        modifier(KeepScreenAwakeModifier(surface: surface, isActive: isActive))
    }
}

private struct KeepScreenAwakeModifier: ViewModifier {
    let surface: ScreenAwakeSurface
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            // onDisappear fires on dismissal AND on every tab switch (the
            // surface is still alive in its stack, but it is no longer the
            // thing being read) — releasing here is what makes "the screen
            // must not stay on after leaving the reader" true for the tab
            // exit too.
            .onDisappear { ScreenAwake.shared.release(surface) }
            .onChange(of: isActive) { _ in sync() }
    }

    private func sync() {
        if isActive {
            ScreenAwake.shared.acquire(surface)
        } else {
            ScreenAwake.shared.release(surface)
        }
    }
}
