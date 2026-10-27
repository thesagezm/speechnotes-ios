import Foundation

/// LaTeX-ish maths → (a) the form the reader sees and (b) the form the TTS
/// engine hears.
///
/// ## Why this exists
///
/// A note written in maths — `$\beta$`, `\sum_{i=1}^{n} x_i`, `E = mc^2` —
/// used to reach the preview as raw source text: the reader saw "beta",
/// "percent", "dollar sign" and the LaTeX markers themselves, because
/// NOTHING in the app understood maths. The TTS engines then pronounced the
/// markers ("backslash", "frac", "dollar") or mangled the glyphs.
///
/// ## The two outputs
///
/// `display` is a Unicode approximation of the typeset formula: `β`, `∑`,
/// `x₁`, `E = mc²`. It is readable, it needs no layout engine, and it is
/// what the preview shows.
///
/// `spoken` is the SAME formula written out in words an engine can say:
/// "beta", "sum from i equals 1 to n of x sub i", "E equals m c squared".
/// Every maths symbol becomes a WORD, because the engines have no phoneme
/// for `∑` or `β` — they either skip the glyph or read its name in a way
/// nobody asked for.
///
/// ## Scope
///
/// This is a READER, not a TeX engine. It handles the constructs real notes
/// carry (fractions, roots, powers, subscripts, Greek, operators, sums and
/// integrals with limits, matrices, `\text{}` words, accents) and leaves
/// anything it does not understand as literal source text rather than
/// guessing. A formula that renders "close enough" beats one that renders
/// as a wall of LaTeX.
public enum MathNotation {

    // MARK: - Public API

    /// One formula, in both forms.
    public struct Formula: Equatable, Hashable, Sendable {
        /// The LaTeX source, as the author wrote it.
        public let source: String
        /// What the reader sees.
        public let display: String
        /// What the engine says.
        public let spoken: String
        /// True for a formula that is its own paragraph (`$$…$$`).
        public let isDisplay: Bool

        public init(source: String, display: String, spoken: String, isDisplay: Bool) {
            self.source = source
            self.display = display
            self.spoken = spoken
            self.isDisplay = isDisplay
        }
    }

    /// One maths region inside a line of text.
    public struct Segment: Equatable, Hashable, Sendable {
        /// The LaTeX source of this region.
        public let source: String
        public let display: String
        public let spoken: String
        /// True when the region was written as a bare command (`\beta`) rather
        /// than inside `$…$`.
        public let isBare: Bool
        /// True when the region is a standalone formula (`$$…$$`) — it gets
        /// its own centred line rather than sitting inside the paragraph.
        public let isDisplay: Bool

        public init(
            source: String,
            display: String,
            spoken: String,
            isBare: Bool,
            isDisplay: Bool = false
        ) {
            self.source = source
            self.display = display
            self.spoken = spoken
            self.isBare = isBare
            self.isDisplay = isDisplay
        }
    }

    /// A line of text split into plain text and maths regions.
    public struct SegmentLine: Equatable, Hashable, Sendable {
        public enum Part: Equatable, Hashable, Sendable {
            case text(String)
            case math(Segment)
        }
        public let parts: [Part]

        public init(parts: [Part]) {
            self.parts = parts
        }
    }

    /// Parse one formula body (the contents between the delimiters).
    ///
    /// - Parameters:
    ///   - source: The LaTeX source, without the `$`/`$$` delimiters.
    ///   - isDisplay: True for `$$…$$` (a formula on its own line).
    /// - Returns: The formula, or nil when the source is empty or is not
    ///   maths at all (an unknown command survives unrecognised, so there
    ///   is nothing to show).
    public static func formula(_ source: String, isDisplay: Bool) -> Formula? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let mode: Mode = isDisplay ? .display : .inline
        var parser = Parser(source: trimmed, mode: mode)
        // ONE parse, TWO walks. The spoken form must describe the same tree
        // the display form shows, so the nodes are parsed once and both
        // renderers read them.
        let nodes = parser.parse()
        let display = Parser.renderList(nodes, mode: mode)
        let spoken = normalizeSpeech(Parser.speakList(nodes))
        // A formula whose source survives COMPLETELY unrecognised renders
        // as its own source — no better than not supporting it, and
        // confusing next to the formulas that DO render. Refuse it, so the
        // caller keeps the original text.
        guard display != trimmed || !trimmed.contains("\\") else { return nil }
        return Formula(source: trimmed, display: display, spoken: spoken, isDisplay: isDisplay)
    }

    /// Split a line into text and maths parts.
    ///
    /// Recognises `$…$` (inline), `$$…$$` (display) and bare commands
    /// (`\beta`). A `$` that has no closing partner is literal text — a note
    /// about prices ("costs $5") must not lose its dollar sign.
    public static func segments(in line: String) -> SegmentLine {
        var parts: [SegmentLine.Part] = []
        var pending = ""
        var index = line.startIndex

        func flushText() {
            if !pending.isEmpty {
                parts.append(.text(pending))
                pending = ""
            }
        }

        while index < line.endIndex {
            let character = line[index]

            // `$$…$$` — display maths.
            if character == "$", line[index...].hasPrefix("$$") {
                let afterOpen = line.index(index, offsetBy: 2)
                let lineEnd = line[index...].firstIndex(of: "\n") ?? line.endIndex
                if let close = line.range(of: "$$", range: afterOpen..<lineEnd) {
                    let body = String(line[afterOpen..<close.lowerBound])
                    if let parsed = formula(body, isDisplay: true) {
                        flushText()
                        parts.append(.math(Segment(
                            source: parsed.source, display: parsed.display,
                            spoken: parsed.spoken, isBare: false, isDisplay: true
                        )))
                        index = close.upperBound
                        continue
                    }
                    pending += String(line[index..<close.upperBound])
                    index = close.upperBound
                    continue
                }
            }

            // `$…$` — inline maths.
            if character == "$" {
                let afterOpen = line.index(after: index)
                // The closing `$` must be on the SAME line: a `$` in the
                // next line of a paragraph is prose, not a formula that
                // happens to wrap. An escaped `\$` inside the body closes
                // nothing — the close search skips escape pairs.
                let lineEnd = line[index...].firstIndex(of: "\n") ?? line.endIndex
                if let close = unescapedDollar(in: line, from: afterOpen, before: lineEnd) {
                    let body = String(line[afterOpen..<close.lowerBound])
                    if looksLikeMath(body),
                       let parsed = formula(body, isDisplay: false) {
                        flushText()
                        parts.append(.math(Segment(
                            source: parsed.source, display: parsed.display,
                            spoken: parsed.spoken, isBare: false
                        )))
                        index = close.upperBound
                        continue
                    }
                }
                pending += "$"
                index = line.index(after: index)
                continue
            }

            // `\$` — an escaped dollar sign is PROSE: it must neither open
            // nor close a formula ("the fee is \$5, once").
            if character == "\\", line[index...].hasPrefix("\\$") {
                pending += "$"
                index = line.index(index, offsetBy: 2)
                continue
            }

            // `\command` — a bare maths command.
            if character == "\\", let command = bareCommand(in: line, at: index) {
                flushText()
                parts.append(.math(command.segment))
                index = command.end
                continue
            }

            pending.append(character)
            index = line.index(after: index)
        }

        flushText()
        return SegmentLine(parts: parts)
    }

    /// The plain text of a line with every maths region replaced by its
    /// SPOKEN form — the TTS contract.
    public static func spokenText(in line: String) -> String {
        var out = ""
        for part in segments(in: line).parts {
            switch part {
            case .text(let text): out += text
            case .math(let segment): out += segment.spoken
            }
        }
        return out
    }

    /// The display form of a line with every maths region replaced by its
    /// Unicode rendering.
    public static func displayText(in line: String) -> String {
        var out = ""
        for part in segments(in: line).parts {
            switch part {
            case .text(let text): out += text
            case .math(let segment): out += segment.display
            }
        }
        return out
    }

    // MARK: - What counts as maths

    /// The first `$` at or after `from` (and before `before`) that is not
    /// part of a `\X` escape pair — an escaped `\$` closes nothing.
    /// Internal so the markdown parser's maths protection pairs regions
    /// exactly the way `segments` does.
    static func unescapedDollar(
        in line: String,
        from: String.Index,
        before: String.Index
    ) -> String.Index? {
        var cursor = from
        while cursor < before {
            if line[cursor] == "$" { return cursor }
            if line[cursor] == "\\" {
                // `\X` (including `\\` and `\$`) is one unit, never a
                // delimiter.
                let after = line.index(after: cursor)
                guard after < before else { return nil }
                cursor = line.index(after: after)
                continue
            }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    /// Whether the text between two `$` signs is a FORMULA rather than
    /// prose that happens to contain a dollar sign.
    ///
    /// This is the line between "costs $5 and $10" (prices — the dollar
    /// signs must survive) and "the value is $x + y$" (a formula). The
    /// rules, in order:
    ///
    ///  • A body of only digits, dots, commas and spaces is MONEY or a bare
    ///    number — not a formula. (`$100`, `$5`)
    ///  • A body that starts or ends with whitespace is prose.
    ///  • A SHORT body of letters — one or two characters — is a VARIABLE
    ///    (`$r$`, `$x$`), which is how maths is actually written.
    ///  • A body with no maths signal at all — no LaTeX command, no
    ///    operator, no Greek, no superscript — is prose. `$hello$` is a
    ///    quoted word, not an equation.
    ///  • Everything else is a formula.
    private static func looksLikeMath(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Prices and bare numbers: digits, separators, spaces only.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." || $0 == " " }) {
            return false
        }
        // Leading/trailing whitespace means the author was writing prose
        // around a dollar sign, not a formula.
        if body.hasPrefix(" ") || body.hasSuffix(" ") { return false }
        // A short all-letter body is a variable.
        if trimmed.count <= 2, trimmed.allSatisfy({ $0.isLetter }) {
            return true
        }
        // A maths signal: a LaTeX command, a maths operator, a Greek letter,
        // a caret/underscript, a brace, a percent (often arriving bare —
        // the markdown parser de-escapes `\%` before this gate runs), an
        // asterisk (multiplication), or a degree mark.
        let signals = ["\\", "^", "_", "{", "}", "=", "<", ">", "+", "−", "±",
                       "×", "÷", "√", "∑", "∏", "∫", "∞", "≤", "≥", "≠",
                       "≈", "→", "←", "α", "β", "γ", "δ", "θ", "λ", "μ",
                       "π", "σ", "φ", "ω", "Δ", "Ω", "Σ", "Π",
                       "%", "*", "°"]
        return signals.contains { body.contains($0) }
    }

    // MARK: - Bare commands

    /// A bare `\command` at `index`, or nil when what follows is not one.
    ///
    /// Returns the segment AND the index just past the command's name, so
    /// the caller knows where the source continues.
    private static func bareCommand(
        in line: String,
        at index: String.Index
    ) -> (segment: Segment, end: String.Index)? {
        let afterSlash = line.index(after: index)
        var name = ""
        var cursor = afterSlash
        while cursor < line.endIndex, line[cursor].isLetter {
            name.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        guard !name.isEmpty else { return nil }
        guard MathCommandTable.bareAllowed.contains(name) else { return nil }
        guard let definition = MathCommandTable.commands[name] else { return nil }

        let segment: Segment
        switch definition.kind {
        case .symbol(let display, let spoken):
            segment = Segment(source: "\\" + name, display: display, spoken: spoken, isBare: true)
        case .function(let display, let spoken):
            segment = Segment(source: "\\" + name, display: display, spoken: spoken, isBare: true)
        case .dots(let display):
            segment = Segment(source: "\\" + name, display: display, spoken: "and so on", isBare: true)
        }
        return (segment, cursor)
    }

    // MARK: - The parser

    /// Rendering mode. `inline` keeps fractions small; `display` allows the
    /// larger forms a standalone formula gets.
    enum Mode {
        case inline
        case display
    }

    /// The LaTeX reader.
    ///
    /// It walks the source once, building a tree of nodes; each node knows
    /// how to render itself (Unicode) and how to say itself (words). The two
    /// walks are separate so the spoken form can be verbose while the display
    /// form stays compact.
    struct Parser {
        let source: String
        let mode: Mode

        private var index: String.Index

        init(source: String, mode: Mode) {
            self.source = source
            self.mode = mode
            self.index = source.startIndex
        }

        // MARK: Node kinds

        indirect enum Node {
            /// Literal text, already rendered to Unicode where possible.
            case text(String)
            /// A symbol with a display glyph and a spoken word.
            case symbol(display: String, spoken: String)
            /// A named function (displayed upright).
            case function(display: String, spoken: String)
            /// A fraction: numerator over denominator.
            case fraction([Node], [Node])
            /// A root: `√(index)(radicand)`.
            case root([Node]?, [Node])
            /// A superscript — the BASE and the EXPONENT together.
            case superscript(base: [Node], exponent: [Node])
            /// A subscript — the BASE and the INDEX together.
            case sub(base: [Node], index: [Node])
            /// A parenthesised group.
            case group([Node])
            /// Prose inside maths (`\text{…}`) — spoken as written, with
            /// its operators left as punctuation.
            case prose([Node])
            /// A big operator with lower and upper limits.
            case bigOperator(display: String, spoken: String, lower: [Node]?, upper: [Node]?)
            /// A matrix (rows of cells).
            case matrix([[[Node]]])
            /// A run of dots.
            case dots(String)
            /// An accent applied to a symbol (`\hat{x}`).
            case accent(String, [Node])
            /// A quantity in degrees — `45^\circ`, `45\degree`. Rendered as
            /// the degree sign, spoken "degrees" (a superscript ring would
            /// be function composition, not a temperature).
            case degrees([Node])
            /// Anything the parser did not recognise — kept verbatim.
            case literal(String)
        }

        // MARK: Walking

        /// Parse the whole source into nodes.
        mutating func parse() -> [Node] {
            var out: [Node] = []
            while index < source.endIndex {
                out.append(parseAtom())
            }
            return out
        }

        /// One ATOM: a base plus any scripts attached to it.
        ///
        /// The scripts belong to the base — `x^2` is ONE thing, a base `x`
        /// with the exponent `2`. Parsing them separately (base, then a
        /// floating exponent) is what made the earlier version render
        /// "x2²": the exponent had no base to attach to.
        mutating func parseAtom() -> Node {
            let base = parseBase()
            return attachScripts(to: base)
        }

        /// The scripts that follow a base: `^` for a power, `_` for an
        /// index. Both may appear (`x^2_1`), in either order.
        mutating func attachScripts(to base: Node) -> Node {
            var result = base
            while index < source.endIndex {
                if source[index] == "^" {
                    index = source.index(after: index)
                    let exponent = parseArgument()
                    // `45^\circ` (or `^{\circ}`) — LaTeX's degree notation.
                    // As an EXPONENT the ring is the degree sign ("45°",
                    // spoken "45 degrees"), not function composition.
                    if exponent.count == 1,
                       case .symbol(let display, _) = exponent[0],
                       display == "∘" {
                        result = .degrees([result])
                        continue
                    }
                    result = .superscript(base: [result], exponent: exponent)
                } else if source[index] == "_" {
                    index = source.index(after: index)
                    let subIndex = parseArgument()
                    result = .sub(base: [result], index: subIndex)
                } else {
                    break
                }
            }
            return result
        }

        /// The base of an atom: a command, a group, an identifier, or one
        /// character.
        mutating func parseBase() -> Node {
            guard index < source.endIndex else { return .text("") }
            let character = source[index]

            if character == "\\" { return parseCommand() }

            if character == "{" {
                return .group(parseBracedGroup())
            }

            if character == "}" {
                // A stray closing brace — keep it rather than swallow it.
                index = source.index(after: index)
                return .text("}")
            }

            if character == "^" || character == "_" {
                // A script with no base (malformed). Keep the marker.
                index = source.index(after: index)
                return .text(String(character))
            }

            // A run of letters and digits is ONE identifier: "mc" in
            // `mc^2` is the base of the power, not two separate atoms.
            var identifier = ""
            while index < source.endIndex, source[index].isLetter || source[index].isNumber {
                identifier.append(source[index])
                index = source.index(after: index)
            }
            if !identifier.isEmpty { return .text(identifier) }

            // Any other character — space, operator, bracket.
            index = source.index(after: index)
            return .text(String(character))
        }

        /// A `{…}` group. The braces are consumed; the contents are parsed
        /// as atoms.
        mutating func parseBracedGroup() -> [Node] {
            // The opening brace is still current.
            index = source.index(after: index)
            var out: [Node] = []
            while index < source.endIndex, source[index] != "}" {
                out.append(parseAtom())
            }
            if index < source.endIndex { index = source.index(after: index) }  // consume "}"
            return out
        }

        /// The argument of a power/subscript: a group, or one atom.
        mutating func parseArgument() -> [Node] {
            skipSpaces()
            guard index < source.endIndex else { return [] }
            if source[index] == "{" {
                return parseBracedGroup()
            }
            return [parseAtom()]
        }

        /// A `\command` and whatever arguments it takes.
        mutating func parseCommand() -> Node {
            index = source.index(after: index)   // consume the backslash
            var name = ""
            while index < source.endIndex, source[index].isLetter {
                name.append(source[index])
                index = source.index(after: index)
            }
            // `\ ` (escaped space) and `\{` / `\}` / `\%` — a literal.
            if name.isEmpty {
                guard index < source.endIndex else { return .literal("\\") }
                let character = source[index]
                index = source.index(after: index)
                return .literal(literalCharacter(character))
            }

            switch name {
            case "frac", "dfrac", "tfrac":
                let numerator = parseGroupArgument()
                let denominator = parseGroupArgument()
                return .fraction(numerator, denominator)
            case "sqrt":
                // `\sqrt[3]{x}` — an optional index.
                skipSpaces()
                var rootIndex: [Node]? = nil
                if index < source.endIndex, source[index] == "[" {
                    index = source.index(after: index)
                    var out: [Node] = []
                    while index < source.endIndex, source[index] != "]" {
                        out.append(parseAtom())
                    }
                    if index < source.endIndex { index = source.index(after: index) }
                    rootIndex = out
                }
                let radicand = parseGroupArgument()
                return .root(rootIndex, radicand)
            case "text", "textrm", "mathrm", "mathbf", "mathit", "mathsf", "mathtt",
                 "operatorname", "mbox":
                // A WORD inside maths — it stays a word, and it is PROSE:
                // the operators in `\text{if x > 5}` are prose punctuation,
                // not formula operators, so they are spoken as they read.
                return .prose(parseGroupArgument())
            case "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle",
                 "textstyle", "limits", "nolimits":
                // Size/placement modifiers — no meaning on their own.
                return .text("")
            case "mathbb", "mathcal", "mathscr", "mathfrak", "boldsymbol":
                // The STYLE is dropped; the letters stay. The reader gets
                // `R` where the source said `\mathbb{R}` — a fair trade for
                // a glyph the phone may not have.
                return .group(parseGroupArgument())
            case "hat", "bar", "vec", "tilde", "dot", "ddot", "overline",
                 "underline", "widehat", "widetilde":
                let accent = accentGlyph(name)
                let base = parseGroupArgument()
                return .accent(accent, base)
            case "begin":
                return parseMatrix()
            case "end":
                // A stray `\end` — the matrix parser consumes the real one.
                consumeEndEnvironment()
                return .text("")
            case "binom":
                let top = parseGroupArgument()
                let bottom = parseGroupArgument()
                return .fraction(top, bottom)
            case "quad":
                return .text("  ")
            case "qquad":
                return .text("    ")
            case ",":
                return .text(" ")
            case ";":
                return .text(" ")
            case "!":
                return .text("")
            case "not":
                // `\not=` — the negation applies to the NEXT symbol, so
                // `\not=` reads "not equal to" rather than "not, equals".
                let next = parseAtom()
                if case .symbol(let display, _) = next, display == "=" {
                    return .symbol(display: "≠", spoken: "not equal to")
                }
                return .symbol(display: "¬", spoken: "not")
            default:
                break
            }

            guard let definition = MathCommandTable.commands[name] else {
                // An unknown command stays literal — a note mentioning
                // `\emph` or a package name must not lose the text.
                return .literal("\\" + name)
            }

            switch definition.kind {
            case .symbol(let display, let spoken):
                // A BIG OPERATOR with limits: `\sum_{i=1}^{n}`. The limits
                // belong to the operator, not to the text after it, so they
                // are read here rather than left to the main loop (which
                // would render "∑_i=1^n" as three separate things).
                if isBigOperator(display) {
                    let limits = parseLimits()
                    return .bigOperator(
                        display: display, spoken: spoken,
                        lower: limits.lower, upper: limits.upper
                    )
                }
                return .symbol(display: display, spoken: spoken)
            case .function(let display, let spoken):
                return .function(display: display, spoken: spoken)
            case .dots(let display):
                return .dots(display)
            }
        }

        /// The argument of a command: a `{…}` group, or one atom.
        mutating func parseGroupArgument() -> [Node] {
            skipSpaces()
            guard index < source.endIndex else { return [] }
            if source[index] == "{" {
                return parseBracedGroup()
            }
            return [parseAtom()]
        }

        /// True for the operators that take limits above and below.
        private func isBigOperator(_ display: String) -> Bool {
            ["∑", "∏", "∫", "∮", "∬", "∭"].contains(display)
        }

        /// The `_lower` and `^upper` that follow a big operator. Either may
        /// be absent, and they may come in either order.
        private mutating func parseLimits() -> (lower: [Node]?, upper: [Node]?) {
            var lower: [Node]? = nil
            var upper: [Node]? = nil
            for _ in 0..<2 {
                skipSpaces()
                guard index < source.endIndex else { break }
                switch source[index] {
                case "_":
                    index = source.index(after: index)
                    lower = parseArgument()
                case "^":
                    index = source.index(after: index)
                    upper = parseArgument()
                default:
                    return (lower, upper)
                }
            }
            return (lower, upper)
        }

        /// The matrix environment: `\begin{matrix}…\end{matrix}`.
        private mutating func parseMatrix() -> Node {
            // Skip the environment name (`{matrix}`, `{pmatrix}`, …).
            skipSpaces()
            if index < source.endIndex, source[index] == "{" {
                _ = parseBracedGroup()
            }
            var rows: [[[Node]]] = []
            var row: [[Node]] = []
            var cell: [Node] = []

            while index < source.endIndex {
                // `\end{…}` closes the environment.
                if atEndEnvironment() {
                    consumeEndEnvironment()
                    break
                }
                // `\\` ends a row.
                if source[index] == "\\" {
                    let after = source.index(after: index)
                    if after < source.endIndex, source[after] == "\\" {
                        index = source.index(after: after)
                        row.append(cell)
                        cell = []
                        if !row.isEmpty { rows.append(row) }
                        row = []
                        continue
                    }
                }
                // `&` ends a cell.
                if source[index] == "&" {
                    row.append(cell)
                    cell = []
                    index = source.index(after: index)
                    continue
                }
                // A stray `}` at this level means the source was malformed.
                if source[index] == "}" { break }
                cell.append(parseAtom())
            }
            if !cell.isEmpty || !row.isEmpty {
                row.append(cell)
                if !row.isEmpty { rows.append(row) }
            }
            return .matrix(rows)
        }

        /// True when the source is at an `\end{…}` marker.
        private func atEndEnvironment() -> Bool {
            guard index < source.endIndex, source[index] == "\\" else { return false }
            let after = source.index(after: index)
            guard after < source.endIndex, source[after] == "e" else { return false }
            let afterE = source.index(after: after)
            guard afterE < source.endIndex, afterE < source.endIndex else { return false }
            return source[afterE...].hasPrefix("nd")
        }

        /// Consume an `\end{…}` marker.
        private mutating func consumeEndEnvironment() {
            // "\end"
            index = source.index(after: index)
            for _ in 0..<3 {
                guard index < source.endIndex else { return }
                index = source.index(after: index)
            }
            // "{name}"
            skipSpaces()
            if index < source.endIndex, source[index] == "{" {
                _ = parseBracedGroup()
            }
        }

        private func accentGlyph(_ name: String) -> String {
            switch name {
            case "hat", "widehat": return "^"
            case "bar", "overline": return "‾"
            case "vec": return "→"
            case "tilde", "widetilde": return "~"
            case "dot": return "˙"
            case "ddot": return "¨"
            default: return ""
            }
        }

        /// The escaped character after a backslash that is not a command.
        private func literalCharacter(_ character: Character) -> String {
            switch character {
            case "%": return "%"
            case "_": return "_"
            case "#": return "#"
            case "&": return "&"
            case "$": return "$"
            case "{": return "{"
            case "}": return "}"
            case "\\": return "\\"
            case " ": return " "
            default: return String(character)
            }
        }

        private mutating func skipSpaces() {
            while index < source.endIndex, source[index] == " " {
                index = source.index(after: index)
            }
        }

        /// The spoken form of a LIST of nodes, with their operators left as
        /// they are — the PROSE path (a matrix cell, `\text{…}`), where
        /// "x > 5" is a sentence and not a formula.
        private static func speakRawList(_ nodes: [Node]) -> String {
            var out = ""
            for node in nodes {
                out += speakRawNode(node)
            }
            return out
        }

        /// The spoken form of a node, with its operators left as they are —
        /// the PROSE path (`\text{…}`), where "x > 5" is a sentence and not
        /// a formula.
        private static func speakRawNode(_ node: Node) -> String {
            switch node {
            case .text(let text):
                return text
            case .literal(let text):
                return text
            case .symbol(_, let spoken):
                return spoken
            case .function(_, let spoken):
                return spoken
            case .dots:
                return "and so on"
            case .group(let children):
                var out = ""
                for child in children { out += speakRawNode(child) }
                return out
            case .prose(let children):
                var out = ""
                for child in children { out += speakRawNode(child) }
                return out
            case .fraction(let numerator, let denominator):
                return "\(speakRawList(numerator)) divided by \(speakRawList(denominator))"
            case .root(let rootIndex, let radicand):
                let body = speakRawList(radicand)
                if let rootIndex {
                    return "the \(speakRawList(rootIndex))th root of \(body)"
                }
                return "the square root of \(body)"
            case .superscript(let base, let exponent):
                return "\(speakRawList(base)) to the power of \(speakRawList(exponent))"
            case .sub(let base, let subIndex):
                return "\(speakRawList(base)) sub \(speakRawList(subIndex))"
            case .bigOperator(_, let spoken, let lower, let upper):
                var out = spoken
                if let lower { out += " from \(speakRawList(lower))" }
                if let upper { out += " to \(speakRawList(upper))" }
                return out
            case .matrix(let rows):
                return rows.map { row in
                    row.map { cell in speakRawList(cell) }.joined(separator: ", ")
                }.joined(separator: ", ")
            case .accent(_, let base):
                return speakRawList(base)
            case .degrees(let base):
                return "\(speakRawList(base)) degrees"
            }
        }

        // MARK: Rendering

        /// The display form of a node list.
        static func renderList(_ nodes: [Node], mode: Mode) -> String {
            var out = ""
            for (offset, node) in nodes.enumerated() {
                out += renderNode(node, mode: mode)
                // A named function is followed by a space: "sin x", not
                // "sinx".
                if case .function = node, offset + 1 < nodes.count,
                   case .text(let next) = nodes[offset + 1], !next.hasPrefix(" ") {
                    out += " "
                }
            }
            return out
        }

        private static func renderNode(_ node: Node, mode: Mode) -> String {
            switch node {
            case .text(let text):
                return text
            case .literal(let text):
                return text
            case .symbol(let display, _):
                return display
            case .function(let display, _):
                return display
            case .dots(let display):
                return display
            case .group(let children):
                return renderList(children, mode: mode)
            case .prose(let children):
                return renderList(children, mode: mode)
            case .fraction(let numerator, let denominator):
                let top = renderList(numerator, mode: mode)
                let bottom = renderList(denominator, mode: mode)
                if mode == .display {
                    return "(\(top))/(\(bottom))"
                }
                return "\(top)/\(bottom)"
            case .root(let rootIndex, let radicand):
                let body = renderList(radicand, mode: mode)
                if let rootIndex {
                    let degree = renderList(rootIndex, mode: mode)
                    return "√[\(degree)](\(body))"
                }
                return "√(\(body))"
            case .superscript(let base, let exponent):
                let baseText = renderList(base, mode: mode)
                let exponentText = renderList(exponent, mode: mode)
                return baseText + superscriptGlyphs(exponentText)
            case .sub(let base, let subIndex):
                let baseText = renderList(base, mode: mode)
                let subscriptText = renderList(subIndex, mode: mode)
                return baseText + subscriptGlyphs(subscriptText)
            case .bigOperator(let display, _, let lower, let upper):
                var out = display
                // The limits stay in plain text: `∑_i=1` reads better than
                // a row of superscript glyphs nobody can parse.
                if let lower { out += "_\(renderList(lower, mode: mode))" }
                if let upper { out += "^\(renderList(upper, mode: mode))" }
                return out
            case .matrix(let rows):
                return rows.map { row in
                    "(" + row.map { cell in renderList(cell, mode: mode) }.joined(separator: ", ") + ")"
                }.joined(separator: ", ")
            case .accent(let glyph, let base):
                let body = renderList(base, mode: mode)
                return glyph.isEmpty ? body : "\(glyph)\(body)"
            case .degrees(let base):
                return renderList(base, mode: mode) + "°"
            }
        }

        /// The spoken form of a node list.
        ///
        /// Every node boundary gets a SEPARATOR. A node list is a sequence of
        /// things the author wrote apart (`i`, `=`, `1` in `\sum_{i=1}`), and
        /// an operator word welded onto its neighbour is not a pause, it is a
        /// different word: "iequals1" instead of "i equals 1". The separator
        /// is a space; the final whitespace pass collapses whatever runs of
        /// spaces the source's own spacing leaves behind.
        static func speakList(_ nodes: [Node]) -> String {
            var out = ""
            for (offset, node) in nodes.enumerated() {
                if offset > 0 { out += " " }
                out += speakNode(node)
            }
            return out
        }

        private static func speakNode(_ node: Node) -> String {
            switch node {
            case .text(let text):
                // The operators in a formula become WORDS: an engine handed
                // "=" reads it as "equals" on a good day and as
                // "equals-sign" on a bad one.
                return speakOperators(text)
            case .literal(let text):
                return text
            case .symbol(_, let spoken):
                return spoken
            case .function(_, let spoken):
                return spoken
            case .dots:
                return "and so on"
            case .group(let children):
                return speakList(children)
            case .prose(let children):
                // Prose keeps its punctuation: "if x > 5" reads as prose,
                // not as "if x greater than 5".
                var out = ""
                for child in children {
                    out += speakRawNode(child)
                }
                return out
            case .fraction(let numerator, let denominator):
                let top = speakList(numerator)
                let bottom = speakList(denominator)
                return "\(top) divided by \(bottom)"
            case .root(let rootIndex, let radicand):
                let body = speakList(radicand)
                if let rootIndex {
                    let degree = speakList(rootIndex)
                    return "the \(degree)th root of \(body)"
                }
                return "the square root of \(body)"
            case .superscript(let base, let exponent):
                let baseText = speakList(base)
                let exponentText = speakList(exponent)
                return "\(baseText) to the power of \(exponentText)"
            case .sub(let base, let subIndex):
                let baseText = speakList(base)
                let subscriptText = speakList(subIndex)
                return "\(baseText) sub \(subscriptText)"
            case .bigOperator(_, let spoken, let lower, let upper):
                var out = spoken
                if let lower {
                    out += " from \(speakList(lower))"
                }
                if let upper {
                    out += " to \(speakList(upper))"
                }
                return out
            case .matrix(let rows):
                let spokenRows = rows.enumerated().map { offset, row -> String in
                    let cells = row.map { cell in speakList(cell) }.joined(separator: ", ")
                    return offset == 0 ? "the matrix \(cells)" : "and \(cells)"
                }
                return spokenRows.joined(separator: ", ")
            case .accent(_, let base):
                return speakList(base)
            case .degrees(let base):
                return "\(speakList(base)) degrees"
            }
        }
    }

    // MARK: - Operators the engine speaks as words

    /// The ASCII operators a formula is built from, and what the engine
    /// says for them.
    ///
    /// The DISPLAY keeps the symbol (`x = 5`, `a + b`) — that is what a
    /// reader expects to see. The SPOKEN form uses a word, because an
    /// engine handed "=" reads it as "equals" on a good day and as
    /// "equals-sign" on a bad one, and "+" comes out as "plus" or as
    /// nothing at all.
    ///
    /// The words carry NO padding: the spacing is decided by the
    /// surrounding text, and the final whitespace pass collapses whatever
    /// the padding leaves behind.
    private static let operatorWords: [Character: String] = [
        "=": "equals",
        "+": "plus",
        "-": "minus",
        "*": "times",
        "/": "divided by",
        "<": "less than",
        ">": "greater than",
        "(": "open bracket",
        ")": "close bracket",
        "[": "open bracket",
        "]": "close bracket",
        "%": "percent",
        "°": "degrees",
    ]

    /// The spoken form of a plain-text run: the operators inside it become
    /// words.
    ///
    /// A word is padded with a space on a side only when the source had no
    /// whitespace there — so `x = 5` keeps its own spacing while `x=5`
    /// becomes "x equals 5" instead of "xequals5".
    private static func speakOperators(_ text: String) -> String {
        var out = ""
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            guard let word = operatorWords[character] else {
                out.append(character)
                continue
            }
            let before = offset > 0 ? characters[offset - 1] : " "
            let after = offset + 1 < characters.count ? characters[offset + 1] : " "
            if !before.isWhitespace { out += " " }
            out += word
            if !after.isWhitespace { out += " " }
        }
        return out
    }

    /// One space between words, no leading or trailing space.
    ///
    /// The operator words bring their own padding, and the source text
    /// brings its own — together they leave runs of spaces ("E  equals  mc")
    /// that the engine reads as a stumble.
    private static func normalizeSpeech(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out += " "
                pendingSpace = false
            }
            out.append(character)
        }
        return out
    }

    // MARK: - Superscript / subscript glyphs
    /// Unicode super/subscript digits and letters. A formula that fits in the
    /// Unicode superscript block (`x²`, `a₀`) reads as a formula; anything
    /// else falls back to the caret form, which every reader understands.
    private static let superscriptMap: [Character: String] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼",
        "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]

    private static let subscriptMap: [Character: String] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌",
        "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    private static func superscriptGlyphs(_ body: String) -> String {
        var out = ""
        for character in body {
            guard let glyph = superscriptMap[character] else { return "^(\(body))" }
            out += glyph
        }
        return out.isEmpty ? "^" : out
    }

    private static func subscriptGlyphs(_ body: String) -> String {
        var out = ""
        for character in body {
            guard let glyph = subscriptMap[character] else { return "_\(body)" }
            out += glyph
        }
        return out.isEmpty ? "_" : out
    }
}
