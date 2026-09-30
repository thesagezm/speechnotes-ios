# Device checklist — v1.7.2 (branch `sage-upgrades`, build 40)

Second v1.7.2 batch: audiobook sleep timer + speed, landscape prev/next
everywhere, movable mini-player bubble, office images/tables/covers, and
Anx-style page-turn settings. Everything below is testable without tools.

## Audiobook reader (portrait)

1. Open an audiobook → under the play cluster there is a chip row:
   **speed** (`gauge` + current rate) and **sleep** (`moon.zzz`).
2. Speed: pick 1.5× → audio audibly faster; the chip label follows; leave
   the reader, the mini-bar keeps playing at 1.5×; lock screen scrubber
   advances at the right pace.
3. Sleep: pick 5 minutes → the chip turns accent-colored and counts down
   (updates each second while PLAYING). Pause the book for a while — the
   countdown must NOT move. Resume → it continues; at 0 the book pauses
   and a toast says "Sleep timer: paused".
4. "End of chapter" sleep option → the book pauses when the current
   chapter finishes instead of rolling into the next one.
5. Cancel timer → chip returns to the plain moon icon.

## Audiobook reader (landscape)

6. The rail carries a **chapter stepper** (prev chevron · `3 / 14` · next
   chevron) — both chevrons step chapters; disabled at the ends.
7. Speed + sleep chips float UNDER the rail (not inside it).

## Books (EPUB/PDF) in landscape

8. EPUB landscape: the rail's top shows `Ch x/y` with chevrons — they step
   chapters. PDF landscape: `Page x/y` chevrons step pages.

## Floating bubble

9. Play an audiobook, minimize to the round bubble → DRAG it anywhere:
   release snaps it to the nearest edge; it stays there across reader
   open/close and app relaunch. A quick TAP still expands it back to the
   bar. Bottom edge parks above the tab bar (never covers it).

## Lock screen

10. Play an audiobook, lock the phone → the player's elapsed time ticks
    every second (not in 10-second lumps).
11. Skip-back/forward buttons (15s) appear on the lock screen player;
    both seek ±15 s. They disappear when playback stops.
12. During TTS note speech, the skip buttons are NOT advertised (chapter
    buttons only).

## Office documents → EPUB

13. Re-import (delete + import, or just import fresh) a DOCX/PPTX/ODP/ODT
    that contains images and tables →
    - images appear in the reader, full content width, in order;
    - tables render as bordered tables (merged cells stay merged, header
      rows shaded);
    - TTS reads table cells as a running comma-joined line, not chopped
      fragments.
14. Shelf: the office book shows a real thumbnail — the document's
    embedded preview when it has one, else a colored tile with the format
    badge (DOC / SLIDES / TEXT) and the title. The meta line says
    Word / ODT / Slides instead of EPUB.
15. Books imported on the previous build get their tile on the next shelf
    open (backfill), no re-import needed.

## Reader page turning (EPUB, Pages mode)

16. Appearance → new **Page turning** section: tap the left third of the
    page → previous; right third → next; middle → hides/shows the bars.
17. "Swap left and right" inverts the zones. Turning either toggle off
    (or both) leaves tap-to-hide on the whole page as before.
18. Swipe gestures honor "Swipe to turn" — off means swiping does nothing.
19. In Scroll mode the section is disabled (footer explains why).
