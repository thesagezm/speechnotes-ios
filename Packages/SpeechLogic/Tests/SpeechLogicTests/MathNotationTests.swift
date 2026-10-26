import XCTest
@testable import SpeechLogic

/// The maths contract, in three parts:
///
///  1. The DISPLAY form — what the reader sees (Unicode glyphs).
///  2. The SPOKEN form — what the TTS engine says (words).
///  3. The integration — a formula inside a note reaches both the preview
///     and the speech path, and prices (`$5`) are NOT mistaken for maths.
final class MathNotationTests: XCTestCase {

    // MARK: - Display form

    func testGreekLetterRendersAsGlyph() {
        let formula = MathNotation.formula("\\beta", isDisplay: false)
        XCTAssertEqual(formula?.display, "β")
    }

    func testUppercaseGreekKeepsItsCase() {
        XCTAssertEqual(MathNotation.formula("\\Omega", isDisplay: false)?.display, "Ω")
        XCTAssertEqual(MathNotation.formula("\\omega", isDisplay: false)?.display, "ω")
    }

    func testOperatorsRenderAsSymbols() {
        XCTAssertEqual(MathNotation.formula("\\times", isDisplay: false)?.display, "×")
        XCTAssertEqual(MathNotation.formula("\\leq", isDisplay: false)?.display, "≤")
        XCTAssertEqual(MathNotation.formula("\\neq", isDisplay: false)?.display, "≠")
        XCTAssertEqual(MathNotation.formula("\\infty", isDisplay: false)?.display, "∞")
    }

    func testFractionRendersAsSlashInlineAndParensWhenDisplayed() {
        XCTAssertEqual(MathNotation.formula("\\frac{a}{b}", isDisplay: false)?.display, "a/b")
        XCTAssertEqual(MathNotation.formula("\\frac{a}{b}", isDisplay: true)?.display, "(a)/(b)")
    }

    func testSquareRootRenders() {
        XCTAssertEqual(MathNotation.formula("\\sqrt{x^2 + y^2}", isDisplay: false)?.display, "√(x² + y²)")
    }

    func testSuperscriptUsesUnicodeGlyphs() {
        XCTAssertEqual(MathNotation.formula("x^2", isDisplay: false)?.display, "x²")
        XCTAssertEqual(MathNotation.formula("E = mc^2", isDisplay: false)?.display, "E = mc²")
    }

    func testSubscriptUsesUnicodeGlyphs() {
        XCTAssertEqual(MathNotation.formula("x_1", isDisplay: false)?.display, "x₁")
        XCTAssertEqual(MathNotation.formula("a_n", isDisplay: false)?.display, "aₙ")
    }

    func testSumWithLimits() {
        let formula = MathNotation.formula("\\sum_{i=1}^{n} x_i", isDisplay: true)
        // The limits stay in plain text: a row of superscript glyphs nobody
        // can parse is worse than `∑_i=1^n`.
        XCTAssertEqual(formula?.display, "∑_i=1^n xᵢ")
    }

    func testIntegralWithLimits() {
        let formula = MathNotation.formula("\\int_0^1 f(x) dx", isDisplay: true)
        XCTAssertNotNil(formula)
        XCTAssertTrue(formula?.display.contains("∫") == true)
    }

    func testUnknownCommandStaysLiteral() {
        // A note mentioning a package name must not lose the text. The
        // parser keeps the source verbatim, and `formula` then REFUSES the
        // formula (there is nothing to show) so the caller keeps the
        // original text.
        let formula = MathNotation.formula("\\emph", isDisplay: false)
        XCTAssertNil(formula, "an unknown command must not become a formula")
    }

    // MARK: - Spoken form

    func testGreekSpokenAsAWord() {
        XCTAssertEqual(MathNotation.formula("\\beta", isDisplay: false)?.spoken, "beta")
        XCTAssertEqual(MathNotation.formula("\\alpha", isDisplay: false)?.spoken, "alpha")
    }

    func testOperatorsSpokenAsWords() {
        XCTAssertEqual(MathNotation.formula("\\times", isDisplay: false)?.spoken, "times")
        XCTAssertEqual(MathNotation.formula("\\leq", isDisplay: false)?.spoken, "less than or equal to")
        XCTAssertEqual(MathNotation.formula("\\neq", isDisplay: false)?.spoken, "not equal to")
        XCTAssertEqual(MathNotation.formula("\\infty", isDisplay: false)?.spoken, "infinity")
    }

    func testFractionSpokenAsDividedBy() {
        let formula = MathNotation.formula("\\frac{a}{b}", isDisplay: false)
        XCTAssertEqual(formula?.spoken, "a divided by b")
    }

    func testSquareRootSpokenAsWords() {
        let formula = MathNotation.formula("\\sqrt{9}", isDisplay: false)
        XCTAssertEqual(formula?.spoken, "the square root of 9")
    }

    func testSuperscriptSpokenAsToThePowerOf() {
        let formula = MathNotation.formula("x^2", isDisplay: false)
        XCTAssertEqual(formula?.spoken, "x to the power of 2")
    }

    func testSubscriptSpokenAsSub() {
        let formula = MathNotation.formula("x_1", isDisplay: false)
        XCTAssertEqual(formula?.spoken, "x sub 1")
    }

    func testSumSpokenWithItsLimits() {
        let formula = MathNotation.formula("\\sum_{i=1}^{n} x_i", isDisplay: true)
        XCTAssertEqual(formula?.spoken, "sum from i equals 1 to n x sub i")
    }

    func testFunctionSpokenAsItsName() {
        XCTAssertEqual(MathNotation.formula("\\sin", isDisplay: false)?.spoken, "sine")
        XCTAssertEqual(MathNotation.formula("\\cos", isDisplay: false)?.spoken, "cosine")
    }

    /// The engine must NEVER receive a raw maths glyph — they are outside
    /// every engine's phoneme vocabulary.
    func testSpokenFormCarriesNoMathsGlyphs() {
        let sources = [
            "\\beta", "\\sum_{i=1}^{n} x_i", "\\frac{a}{b}", "\\sqrt{x}",
            "x^2", "\\leq", "\\infty", "\\times", "\\int_0^1 x dx",
        ]
        let glyphs: Set<Character> = ["β", "α", "γ", "δ", "∑", "∏", "∫", "√",
                                      "≤", "≥", "≠", "∞", "×", "÷", "π", "λ"]
        for source in sources {
            guard let formula = MathNotation.formula(source, isDisplay: true) else {
                XCTFail("no formula for \(source)"); continue
            }
            for character in formula.spoken {
                XCTAssertFalse(glyphs.contains(character),
                               "\(source) speaks the glyph \(character)")
            }
        }
    }

    // MARK: - Segments in a line

    func testInlineFormulaSplitsTheLine() {
        let line = MathNotation.segments(in: "the rate is $r$ today")
        XCTAssertEqual(line.parts.count, 3)
        if case .text(let before) = line.parts[0] {
            XCTAssertEqual(before, "the rate is ")
        } else {
            XCTFail("expected prose first")
        }
        if case .math(let formula) = line.parts[1] {
            XCTAssertEqual(formula.display, "r")
            XCTAssertEqual(formula.spoken, "r")
        } else {
            XCTFail("expected a formula")
        }
        if case .text(let after) = line.parts[2] {
            XCTAssertEqual(after, " today")
        } else {
            XCTFail("expected prose last")
        }
    }

    func testBareCommandIsRecognised() {
        let line = MathNotation.segments(in: "the value \\beta rises")
        let maths = line.parts.compactMap { part -> MathNotation.Segment? in
            if case .math(let segment) = part { return segment }
            return nil
        }
        XCTAssertEqual(maths.count, 1)
        XCTAssertEqual(maths.first?.display, "β")
        XCTAssertTrue(maths.first?.isBare == true)
    }

    func testBareFunctionNameIsNotMaths() {
        // `C:\Users\max` is a PATH, not a formula.
        let line = MathNotation.segments(in: #"C:\Users\max\file"#)
        let maths = line.parts.compactMap { part -> MathNotation.Segment? in
            if case .math(let segment) = part { return segment }
            return nil
        }
        XCTAssertEqual(maths.count, 0, "a windows path was read as maths")
    }

    func testDollarAmountIsNotMaths() {
        // Prices must keep their dollar signs.
        for text in ["costs $5", "it is $100 and $250", "$5"] {
            let line = MathNotation.segments(in: text)
            let maths = line.parts.compactMap { part -> MathNotation.Segment? in
                if case .math(let segment) = part { return segment }
                return nil
            }
            XCTAssertEqual(maths.count, 0, "\(text) was read as maths")
        }
    }

    func testUnclosedDollarIsLiteralText() {
        let line = MathNotation.segments(in: "the price is $5 and rising")
        XCTAssertEqual(line.parts.count, 1)
        if case .text(let text) = line.parts[0] {
            XCTAssertEqual(text, "the price is $5 and rising")
        } else {
            XCTFail("expected plain text")
        }
    }

    func testDisplayFormulaIsMarkedAsSuch() {
        let line = MathNotation.segments(in: "$$x^2$$")
        guard case .math(let formula) = line.parts.first else {
            XCTFail("expected a formula"); return
        }
        XCTAssertTrue(formula.isDisplay)
    }

    // MARK: - Integration with the markdown pipeline

    func testFormulaInParagraphRendersAsGlyphAndSpeaksAsWord() {
        let markdown = "the rate is $\\beta$ today"
        let blocks = MarkdownText.blocks(markdown)
        guard case .paragraph(_, let spans)? = blocks.first else {
            XCTFail("expected a paragraph"); return
        }
        let maths = spans.filter(\.isMath)
        XCTAssertEqual(maths.count, 1)
        XCTAssertEqual(maths.first?.text, "β", "the reader should see the glyph")
        // And the engine says the WORD.
        XCTAssertEqual(MarkdownText.plainText(markdown), "the rate is beta today")
    }

    func testDisplayFormulaBecomesItsOwnBlock() {
        let markdown = """
        before

        $$E = mc^2$$

        after
        """
        let blocks = MarkdownText.blocks(markdown)
        guard case .math(let display, let spoken)? = blocks.first(where: {
            if case .math = $0 { return true } else { return false }
        }) else {
            XCTFail("expected a maths block, got \(blocks)"); return
        }
        // The reader sees the symbol; the engine hears the word.
        XCTAssertEqual(display, "E = mc²")
        XCTAssertEqual(spoken, "E equals mc to the power of 2")
    }

    func testSpeechNeverContainsTheDollarMarkers() {
        let markdown = "value $x + y$ here"
        let spoken = MarkdownText.plainText(markdown)
        XCTAssertFalse(spoken.contains("$"), "the engine heard a dollar sign: \(spoken)")
        // The operators become WORDS — an engine handed "+" reads it as
        // "plus" on a good day and as nothing at all on a bad one.
        XCTAssertEqual(spoken, "value x plus y here")
    }

    func testRawDraftPathAlsoSpeaksMathsAsWords() {
        // The editing path speaks RAW text (the draft is not rendered yet).
        let spoken = MarkdownText.speechInline("value $x + y$ here")
        XCTAssertFalse(spoken.contains("$"), "the engine heard a dollar sign: \(spoken)")
    }

    func testFormulaInsideAListItemSpeaksAsAWord() {
        let markdown = "- the rate is $\\beta$"
        XCTAssertEqual(MarkdownText.plainText(markdown), "the rate is beta")
    }

    func testFormulaInsideAQuoteSpeaksAsAWord() {
        let markdown = "> the rate is $\\beta$"
        XCTAssertEqual(MarkdownText.plainText(markdown), "the rate is beta")
    }

    func testFormulaInsideATableCellSpeaksAsAWord() {
        let markdown = """
        | term | value |
        | --- | --- |
        | rate | $\\beta$ |
        """
        XCTAssertEqual(MarkdownText.plainText(markdown), "term, value\nrate, beta")
    }

    func testPlainNoteIsUnaffected() {
        let markdown = "Just a normal note with a $ sign and 100% of my energy."
        XCTAssertEqual(
            MarkdownText.plainText(markdown),
            "Just a normal note with a $ sign and 100% of my energy."
        )
    }

    func testInlineRunCarriesTheFormula() {
        let runs = MarkdownText.inlineRuns("the rate $\\beta$")
        guard let mathRun = runs.first(where: { run in
            if case .math = run { return true } else { return false }
        }) else {
            XCTFail("expected a maths run, got \(runs)"); return
        }
        if case .math(let display, let spoken) = mathRun {
            XCTAssertEqual(display, "β")
            XCTAssertEqual(spoken, "beta")
        }
    }

    /// The AST resolves emphasis into FLAGS — cmark strips the `**` markers
    /// and sets `bold` on the span. The preview styles from those flags, so
    /// this contract is what keeps bold text bold.
    func testEmphasisArrivesAsFlagsOnTheRun() {
        let runs = MarkdownText.inlineRuns("plain **bold** more")
        guard let boldRun = runs.first(where: { run in
            if case .text(_, let bold, _, _, _) = run { return bold } else { return false }
        }) else {
            XCTFail("expected a bold run, got \(runs)"); return
        }
        if case .text(let text, _, _, _, _) = boldRun {
            // The MARKERS are gone — the flag is the styling.
            XCTAssertEqual(text, "bold")
        }
    }
}
