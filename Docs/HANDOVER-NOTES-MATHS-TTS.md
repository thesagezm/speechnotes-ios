# Handover — notes maths rendering + TTS word forms (branch `batch-c-d-session`)

**SUPERSEDED 2026-10-26 by commit `e1b290a` — the red test is fixed, the
open items are built, and CI is green. Kept for the record; read
`PROGRESS_LOG.md` for the current state.**

State as of 2026-10-26, commit `ca068b2`. **One test failing, 480 passing.
The unsigned IPA job BUILDS GREEN.** No device testing yet.

## The ask

> "in notes preview doesnt render formulas and maths symbols (e.g. beta /// it
> ends up showing percentages dollar signs or words...) … also work out how
> they should be handled by tts"
>
> "in the new minimisable bottom bar… for the normal audiobook player in
> portrait the playback speed and the sleep timer are not centered… the
> minimise icon also seems a bit out of place"

Two independent pieces of work. Both are implemented; one test is red.

## What was built

### 1. Maths in SpeechLogic (new)

| File | Role |
|---|---|
| `Packages/SpeechLogic/Sources/SpeechLogic/MathCommands.swift` | The LaTeX command table. Every entry carries a `display` (Unicode glyph) AND a `spoken` (word): `\beta` → `β` / "beta", `\leq` → `≤` / "less than or equal to". ~150 entries: Greek, operators, relations, arrows, big operators, named functions, constants, dots. |
| `Packages/SpeechLogic/Sources/SpeechLogic/MathNotation.swift` | The parser. One parse, two walks — `render` (Unicode for the screen) and `speak` (words for the engine). |
| `Packages/SpeechLogic/Tests/SpeechLogicTests/MathNotationTests.swift` | 20 tests, mostly passing. |

**Rendering coverage:** `\beta` → `β`; `\frac{a}{b}` → `a/b` inline, `(a)/(b)`
display; `\sqrt{x^2+y^2}` → `√(x² + y²)`; `x^2` → `x²` (Unicode superscripts
where they exist, `^(…)` fallback); `x_1` → `x₁`; `\sum_{i=1}^{n} x_i` →
`∑_i=1^n xᵢ`; `\text{…}` words; accents; `\begin{matrix}`; big-operator limits.
`$$…$$` becomes its own centred `.math` block; `$…$` rides inside the
paragraph. A bare `\beta` (no delimiters) is recognised too.

**TTS — the answer to "how should they be handled":**

The engines have no phoneme for maths glyphs, so every symbol is replaced by
a WORD before it reaches them. `StyledSpan` therefore carries two strings:
`text` (glyphs, for the screen) and `math.spoken` (words, for the engine).
`E = mc^2` displays as "E = mc²" and is spoken as "E equals mc to the power of
2". The ASCII operators get the same treatment (`=` → "equals", `+` →
"plus"). Math in list items, quotes, table cells and headings all speak
correctly, because the speech path reads the spans, not the joined text.

### Integration into `MarkdownText.swift`

- `MarkdownBlock.math(display:spoken)` — a new block case for `$$…$$`.
- `StyledSpan` gained `math: MathNotation.Segment?` plus `.isMath` / `.spoken`.
- `InlineRun.math(display:spoken)`; `InlineRun.text` now carries the AST's
  emphasis flags (`bold/italic/code/strike`).
- `blocks(_:)` splits text spans on maths and promotes a lone `$$…$$`
  paragraph to a `.math` block.
- `speechInline(_:)` (the raw-draft editing path) also speaks maths as words.

### 2. Preview rendering (`MarkdownPreviewView.swift`)

Inline formulas ride inside the paragraph's `Text` in the maths serif face,
tinted with the accent colour. `$$…$$` gets its own centred line. Headings,
quotes, list items and table cells now render through `styledSpans(_:)`
instead of joining their spans into one string — which is how maths (and the
AST's emphasis flags) reached those blocks at all.

### 3. The audiobook portrait bar (`BookAudioReaderView.swift`)

**Centred.** The speed and sleep chips were pinned to the leading edge with
the minimise chevron alone at the trailing edge — two chips on one side, a
lone button on the other, while the transport row above and the time readout
below were both centred. The chips now sit between two equal `Spacer`s (the
ZStack/overlay attempt is gone — equal spacers are what actually centre), and
the chevron rides as a trailing `.overlay(alignment:.trailing)` so it cannot
push the pair off-centre.

**Fixed the out-of-place icon.** The chevron was missing
`.buttonStyle(.plain)` — every other minimise button in the app
(`PlayerControlsBar`, `BookPlayerBar`, `MinimizedBookTransport`) has it. Without
it the button inherited the accent tint and default button chrome, which is
most of why it read as "out of place" next to the two neutral chips.
`.contentShape(Circle())` was added for the hit area.

## The one red test — root-caused, fix known

```
MathNotationTests.swift:108 testSumSpokenWithItsLimits
  expected: "sum from i equals 1 to n x sub i"
  actual:   "sum from iequals1 to n x sub i"
```

**Cause:** `normalizeSpeech` collapses a whitespace run to one space, but it
only *inserts* a space after a non-space character. In `speakOperators`, the
padding around an operator word is decided by the source text — `i=1` has no
spaces around the `=`, so the word "equals" is emitted with a leading space
only if `!before.isWhitespace`. That works, but the spaces the word itself
brings are then adjacent to the *neighbouring words* emitted by separate node
walks (`i`, then the symbol, then `1`), and `normalizeSpeech` eats the run when
`out` is still empty — or the words from consecutive nodes are concatenated
with no separator at all.

The string says "iequals1", so the separator was lost between nodes, not
inside the operator. Concretely: `speakList` joins each node's output with no
separator (`out += speakNode(node)`), relying on the source's own spaces. The
bigOperator's limits are separate NODES, so "i", "=" and "1" concatenate with
nothing between them; `speakOperators` adds a space around "equals" only when
the character *inside its own node text* is non-whitespace, and it is — but the
space is appended AFTER the word, i.e. "i" + " equals" + "1" = "i equals1",
which then… reads as "iequals1" only if the leading space was also dropped.

**Two ways to fix (pick one):**

1. **In `speakList`, join nodes with a space and let `normalizeSpeech` collapse
   the runs.** One line: `out += speakNode(node) + " "` (or append a space
   before each node except the first). This is the robust fix — every node
   boundary gets a separator, so no operator word can weld onto its neighbour.
   Verify it does not double spaces after `.dots`/`.function`, which
   `normalizeSpeech` already collapses.
2. **Make `speakOperators` always pad both sides.** Change the two
   `if !before.isWhitespace` / `if !after.isWhitespace` guards to unconditional
   `out += " "` before and after the word. Simplest, but it injects a space
   even where the source deliberately had none, so `\sin x` becomes
   "sine  x" until `normalizeSpeech` collapses it — acceptable, still one
   whitespace pass.

Option 1 is preferred: it fixes the whole class of bug (any node boundary),
not just this operator.

## Ordered next steps

1. ~~**Fix the red test**~~ — DONE in `e1b290a`. Option 1 was taken:
   `speakList` joins the nodes with a separator, so no operator word can
   weld onto its neighbour. `normalizeSpeech` collapses the runs it
   leaves.
2. **Device round** — the real acceptance test:
   - A note with `$...$`, `$$...$$`, `\beta`, `\sum_{i=1}^{n}`, `\frac{a}{b}`.
     Check the preview renders glyphs, not LaTeX source.
   - **Prices must survive**: "it was $5 and $10" must NOT become a formula,
     and "50% of the time" must keep its percent sign. `looksLikeMath` guards
     this but it has never run on a device.
   - Press play, confirm spoken text says "beta" and not "backslash beta".
     Settings → Logs → filter "WebArticle" is the wrong log here; there is no
     maths-specific log yet — check via the read-along text, which IS the
     spoken text.
   - A bare `\beta` in a sentence renders (no delimiters needed).
   - A Windows path (`C:\Users\max`) must stay literal — `bareAllowed` excludes
     function names for this reason.
   - The new formula button and `/math` insert a delimited formula with the
     body selected.
3. ~~**Insert affordance**~~ — DONE in `e1b290a`. The formatting bar has a
   formula button; the slash menu has `/math` and `/mathblock`. Both insert
   the DELIMITED form (the delimiters are what tell the parser the run is a
   formula, so prices keep their own dollar signs) and leave the body
   selected to type over.
4. ~~**PDF export**~~ — DECIDED and DONE in `e1b290a`. The export carries the
   DISPLAY form (the glyphs), because a shared PDF or text file is a document
   the recipient READS, not a performance of the note. `MarkdownText` gained
   a `displayText(_:)` path; `plainText(_:)` (the speech path) is untouched.

## Notes for the next session

- **No local Swift toolchain in this environment.** Everything is verified
  through GitHub Actions: `gh workflow run build.yml --ref batch-c-d-session`
  then `Scripts/watch_ci.sh <sha>` in the background. The `logic-tests` job is
  the fast signal (it fails in ~50 s when SpeechLogic does not compile);
  `Build unsigned IPA` catches app-target errors.
- **Version policy:** do not bump `MARKETING_VERSION` for a feature. The user
  groups features into releases. Current is 1.8.0/45 (unchanged here).
- **Two `subscript` gotchas, both already hit:** `subscript` is a Swift
  keyword and cannot be an enum case or binding name (renamed to `.sub`), and
  `render`/`speak` had node and node-list overloads under the same name that
  Swift could not disambiguate (now `renderNode`/`renderList`,
  `speakNode`/`speakList`, plus `speakRawNode`/`speakRawList` for the prose
  path).
- **The emphasis change is load-bearing and subtle.** cmark STRIPS the `**`
  markers from the AST text and sets the span's flags instead, so the preview's
  old regex could only ever find markers that were no longer there. Styling now
  comes from the AST flags via `InlineRun` — the regex and its cache were
  deleted. If you re-add a regex path, it will silently do nothing.
