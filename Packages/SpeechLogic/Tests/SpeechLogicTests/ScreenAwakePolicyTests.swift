import XCTest
@testable import SpeechLogic

/// The "Keep Screen On" decision. The app target's UIApplication side is
/// device-only; these tests pin the part that can be reasoned about: the
/// key/default contract between the toggle and the controller, the
/// restore-on-empty invariant, and the note-editor scope rule.
final class ScreenAwakePolicyTests: XCTestCase {

    // MARK: The key/default contract

    /// The toggle (`@AppStorage`) and the controller (UserDefaults read)
    /// must name the SAME key or the feature silently does nothing.
    func testPreferenceKeyIsStable() {
        XCTAssertEqual(ScreenAwakePolicy.preferenceKey, "keepScreenOn")
    }

    func testDefaultIsOn() {
        XCTAssertTrue(ScreenAwakePolicy.defaultEnabled)
    }

    // MARK: The decision

    /// Off is off, no matter what is on screen.
    func testPreferenceOffNeverKeepsAwake() {
        XCTAssertFalse(ScreenAwakePolicy.shouldKeepScreenAwake(
            preferenceEnabled: false,
            activeSurfaces: [.epubReader, .pdfReader, .audiobookReader, .noteReader]
        ))
    }

    /// The restore invariant: no surface means the system timer runs, even
    /// with the preference on. This is what "leaving the reader must not
    /// leave the screen pinned on" is built on.
    func testNoSurfacesNeverKeepsAwake() {
        XCTAssertFalse(ScreenAwakePolicy.shouldKeepScreenAwake(
            preferenceEnabled: true,
            activeSurfaces: []
        ))
    }

    func testPreferenceOnWithASurfaceKeepsAwake() {
        for surface in ScreenAwakeSurface.allCases {
            XCTAssertTrue(ScreenAwakePolicy.shouldKeepScreenAwake(
                preferenceEnabled: true,
                activeSurfaces: [surface]
            ), "\(surface.rawValue) should hold the screen awake")
        }
    }

    /// Two surfaces alive at once (the tab-switch overlap: a reader alive
    /// in the Books stack while the Notes stack shows the editor) keep the
    /// screen awake until the LAST one lets go — one surface disappearing
    /// must not clear another's hold.
    func testOverlappingSurfacesStayAwakeUntilTheLast() {
        var surfaces: Set<ScreenAwakeSurface> = [.epubReader, .noteReader]
        XCTAssertTrue(ScreenAwakePolicy.shouldKeepScreenAwake(preferenceEnabled: true, activeSurfaces: surfaces))

        surfaces.remove(.epubReader)
        XCTAssertTrue(ScreenAwakePolicy.shouldKeepScreenAwake(
            preferenceEnabled: true,
            activeSurfaces: surfaces
        ), "the surviving surface must still hold the screen")

        surfaces.remove(.noteReader)
        XCTAssertFalse(ScreenAwakePolicy.shouldKeepScreenAwake(preferenceEnabled: true, activeSurfaces: surfaces))
    }

    // MARK: The note-editor scope rule

    func testNotePreviewIsAReadingSurface() {
        XCTAssertTrue(ScreenAwakePolicy.noteIsReadingSurface(
            renderMarkdown: true, showPreview: true, readAlongShowing: false
        ))
    }

    func testNoteEditIsNotAReadingSurface() {
        XCTAssertFalse(ScreenAwakePolicy.noteIsReadingSurface(
            renderMarkdown: true, showPreview: false, readAlongShowing: false
        ))
        // Render Markdown off: the editor has no preview mode at all —
        // showPreview's stored true is meaningless there.
        XCTAssertFalse(ScreenAwakePolicy.noteIsReadingSurface(
            renderMarkdown: false, showPreview: true, readAlongShowing: false
        ))
    }

    /// Read-along is reading even though the editor sits in "edit" mode
    /// under it — the highlighted reader replaces the surface.
    func testReadAlongIsAReadingSurfaceEvenInEditMode() {
        XCTAssertTrue(ScreenAwakePolicy.noteIsReadingSurface(
            renderMarkdown: false, showPreview: false, readAlongShowing: true
        ))
    }
}
