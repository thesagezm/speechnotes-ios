# Landscape ⇄ portrait rotation — making it smooth

The v1.6.2 rails work, but the rotation itself is janky. This documents what
animates today, why it stutters, and the fix.

## What changes on rotation today

Each reading surface holds `@Environment(\.isLandscape)` and picks between two
layouts:

```
NoteEditorView   portrait: VStack { content; PlayerControlsBar }
                 landscape: HStack { content; PlaybackRail }
```

The same in `BookReaderView`, `BookPDFReaderView`, `BookAudioReaderView`.

## Why it stutters

1. **Two different container types.** A `VStack` and an `HStack` are structurally
   different views; SwiftUI cannot interpolate between them. On rotation it
   tears down the old tree and builds a new one — no implicit animation exists,
   so the content jumps. Any child that animates independently (a `List`'s
   scroll position, the webview reload, the PDF page render) does its own
   thing at its own time.
2. **`PlayerControlsBar` remounts.** Its `GeometryReader` progress bar, the
   voice chip and the slider all lose state between the two forms.
3. **The rail's vertical slider is a rotated `Slider`** — on the way in and out
   it is re-laid-out from scratch, and the `.rotationEffect` hit area is
   recomputed mid-transition.
4. **No transition is declared.** A rotation is just an environment change;
   nothing tells SwiftUI this is a *guided* layout change, so it does the
   default (instant), and the frames that arrive one after another look like a
   flicker rather than a rotation.

## The fix: one layout, geometry-driven

Keep ONE container for both orientations and let it arrange its children by
available space, so the tree is stable across rotation and only the child
frames animate:

```
NoteEditorView
  HStack(spacing: 0) {          // always HStack
     content
     controls                    // column in portrait, rail in landscape
  }
```

The `controls` child keeps its identity: it is the same view, arranged
vertically in one case and horizontally in the other. SwiftUI still cannot
cross-fade a VStack into an HStack, but the *content* never unmounts, so the
expensive part (editor text, webview, PDF render) stays put and only the
control strip re-arranges.

Two further pieces:

- **`.animation(_:value:)` scoped to the orientation read**, so the change is
  guided rather than a hard cut. Not a global root animation (that rasterises
  the nav bar blurry — the iOS 26 / LiveContainer artefact the project already
  hit once).
- **The rail re-uses the portrait bar's subviews** (the same play button, the
  same progress capsule) so no state is lost mid-rotation.

## What is deliberately NOT animated

- The webview in `BookReaderView` — a WKWebView re-layout is not smooth at any
  duration; it re-rendered on rotation already, and animating the container
  makes it worse. The reader keeps its snap.
- `ZoomableImageView` — user transform, never automated.

## Verification

1. Rotate mid-playback in each surface (note editor, EPUB, PDF, audiobook) —
   content stays mounted, controls slide to the new edge, no blank frame.
2. Rotate while typing — keyboard accessory bar stays anchored.
3. Rotate during a chapter auto-advance gap — mini-player doesn't jitter.
