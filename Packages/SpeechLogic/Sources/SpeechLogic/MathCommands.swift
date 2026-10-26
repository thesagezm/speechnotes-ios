import Foundation

/// The LaTeX command table behind `MathNotation`.
///
/// Every entry carries TWO forms of the same symbol:
///  • `display` — what the reader sees (the Unicode glyph, e.g. `β`, `×`, `≤`).
///  • `spoken`  — what the TTS engine says (`beta`, `times`, `less than or
///    equal to`).
///
/// The two must never be derived from each other: the engines choke on raw
/// Greek/maths glyphs (they are outside the phoneme vocabulary) and a reader
/// hates hearing "backslash beta", so the spoken form is a WORD here.
///
/// Structural commands (`\frac`, `\sqrt`, `\text`, `\left`…) are NOT in this
/// table — the parser handles them directly because they take arguments.
enum MathCommandTable {

    struct Definition {
        enum Kind {
            /// A glyph with a word for it.
            case symbol(display: String, spoken: String)
            /// A named function: displayed upright (`sin`), spoken as a word
            /// (`sine`).
            case function(display: String, spoken: String)
            /// A run of dots.
            case dots(display: String)
        }
        let kind: Kind
    }

    // MARK: - The table

    static let commands: [String: Definition] = [
        // Greek — lowercase.
        "alpha": .init(kind: .symbol(display: "α", spoken: "alpha")),
        "beta": .init(kind: .symbol(display: "β", spoken: "beta")),
        "gamma": .init(kind: .symbol(display: "γ", spoken: "gamma")),
        "delta": .init(kind: .symbol(display: "δ", spoken: "delta")),
        "epsilon": .init(kind: .symbol(display: "ϵ", spoken: "epsilon")),
        "varepsilon": .init(kind: .symbol(display: "ε", spoken: "epsilon")),
        "zeta": .init(kind: .symbol(display: "ζ", spoken: "zeta")),
        "eta": .init(kind: .symbol(display: "η", spoken: "eta")),
        "theta": .init(kind: .symbol(display: "θ", spoken: "theta")),
        "vartheta": .init(kind: .symbol(display: "ϑ", spoken: "theta")),
        "iota": .init(kind: .symbol(display: "ι", spoken: "iota")),
        "kappa": .init(kind: .symbol(display: "κ", spoken: "kappa")),
        "lambda": .init(kind: .symbol(display: "λ", spoken: "lambda")),
        "mu": .init(kind: .symbol(display: "μ", spoken: "mu")),
        "nu": .init(kind: .symbol(display: "ν", spoken: "nu")),
        "xi": .init(kind: .symbol(display: "ξ", spoken: "xi")),
        "omicron": .init(kind: .symbol(display: "ο", spoken: "omicron")),
        "pi": .init(kind: .symbol(display: "π", spoken: "pi")),
        "rho": .init(kind: .symbol(display: "ρ", spoken: "rho")),
        "varrho": .init(kind: .symbol(display: "ϱ", spoken: "rho")),
        "sigma": .init(kind: .symbol(display: "σ", spoken: "sigma")),
        "varsigma": .init(kind: .symbol(display: "ς", spoken: "sigma")),
        "tau": .init(kind: .symbol(display: "τ", spoken: "tau")),
        "upsilon": .init(kind: .symbol(display: "υ", spoken: "upsilon")),
        "phi": .init(kind: .symbol(display: "φ", spoken: "phi")),
        "varphi": .init(kind: .symbol(display: "ϕ", spoken: "phi")),
        "chi": .init(kind: .symbol(display: "χ", spoken: "chi")),
        "psi": .init(kind: .symbol(display: "ψ", spoken: "psi")),
        "omega": .init(kind: .symbol(display: "ω", spoken: "omega")),

        // Greek — uppercase.
        "Gamma": .init(kind: .symbol(display: "Γ", spoken: "Gamma")),
        "Delta": .init(kind: .symbol(display: "Δ", spoken: "Delta")),
        "Theta": .init(kind: .symbol(display: "Θ", spoken: "Theta")),
        "Lambda": .init(kind: .symbol(display: "Λ", spoken: "Lambda")),
        "Xi": .init(kind: .symbol(display: "Ξ", spoken: "Xi")),
        "Pi": .init(kind: .symbol(display: "Π", spoken: "Pi")),
        "Sigma": .init(kind: .symbol(display: "Σ", spoken: "Sigma")),
        "Upsilon": .init(kind: .symbol(display: "Υ", spoken: "Upsilon")),
        "Phi": .init(kind: .symbol(display: "Φ", spoken: "Phi")),
        "Psi": .init(kind: .symbol(display: "Ψ", spoken: "Psi")),
        "Omega": .init(kind: .symbol(display: "Ω", spoken: "Omega")),

        // Binary operators.
        "times": .init(kind: .symbol(display: "×", spoken: "times")),
        "cdot": .init(kind: .symbol(display: "·", spoken: "times")),
        "div": .init(kind: .symbol(display: "÷", spoken: "divided by")),
        "pm": .init(kind: .symbol(display: "±", spoken: "plus or minus")),
        "mp": .init(kind: .symbol(display: "∓", spoken: "minus or plus")),
        "ast": .init(kind: .symbol(display: "∗", spoken: "times")),
        "star": .init(kind: .symbol(display: "⋆", spoken: "star")),
        "circ": .init(kind: .symbol(display: "∘", spoken: "composed with")),
        "bullet": .init(kind: .symbol(display: "•", spoken: "times")),
        "oplus": .init(kind: .symbol(display: "⊕", spoken: "plus")),
        "otimes": .init(kind: .symbol(display: "⊗", spoken: "times")),
        "odot": .init(kind: .symbol(display: "⊙", spoken: "dot")),
        "dagger": .init(kind: .symbol(display: "†", spoken: "dagger")),
        "ddagger": .init(kind: .symbol(display: "‡", spoken: "double dagger")),

        // Relations.
        "leq": .init(kind: .symbol(display: "≤", spoken: "less than or equal to")),
        "le": .init(kind: .symbol(display: "≤", spoken: "less than or equal to")),
        "geq": .init(kind: .symbol(display: "≥", spoken: "greater than or equal to")),
        "ge": .init(kind: .symbol(display: "≥", spoken: "greater than or equal to")),
        "neq": .init(kind: .symbol(display: "≠", spoken: "not equal to")),
        "ne": .init(kind: .symbol(display: "≠", spoken: "not equal to")),
        "approx": .init(kind: .symbol(display: "≈", spoken: "approximately equal to")),
        "equiv": .init(kind: .symbol(display: "≡", spoken: "is equivalent to")),
        "sim": .init(kind: .symbol(display: "∼", spoken: "is similar to")),
        "simeq": .init(kind: .symbol(display: "≃", spoken: "is asymptotically equal to")),
        "propto": .init(kind: .symbol(display: "∝", spoken: "is proportional to")),
        "subset": .init(kind: .symbol(display: "⊂", spoken: "is a subset of")),
        "subseteq": .init(kind: .symbol(display: "⊆", spoken: "is a subset of or equal to")),
        "supset": .init(kind: .symbol(display: "⊃", spoken: "is a superset of")),
        "supseteq": .init(kind: .symbol(display: "⊇", spoken: "is a superset of or equal to")),
        "in": .init(kind: .symbol(display: "∈", spoken: "is an element of")),
        "notin": .init(kind: .symbol(display: "∉", spoken: "is not an element of")),
        "ni": .init(kind: .symbol(display: "∋", spoken: "is an element of")),
        "perp": .init(kind: .symbol(display: "⊥", spoken: "is perpendicular to")),
        "parallel": .init(kind: .symbol(display: "∥", spoken: "is parallel to")),
        "mid": .init(kind: .symbol(display: "∣", spoken: "divides")),
        "doteq": .init(kind: .symbol(display: "≐", spoken: "is defined as")),

        // Arrows.
        "to": .init(kind: .symbol(display: "→", spoken: "right arrow")),
        "rightarrow": .init(kind: .symbol(display: "→", spoken: "right arrow")),
        "gets": .init(kind: .symbol(display: "←", spoken: "left arrow")),
        "leftarrow": .init(kind: .symbol(display: "←", spoken: "left arrow")),
        "leftrightarrow": .init(kind: .symbol(display: "↔", spoken: "left right arrow")),
        "Leftrightarrow": .init(kind: .symbol(display: "⇔", spoken: "if and only if")),
        "Rightarrow": .init(kind: .symbol(display: "⇒", spoken: "implies")),
        "implies": .init(kind: .symbol(display: "⟹", spoken: "implies")),
        "mapsto": .init(kind: .symbol(display: "↦", spoken: "maps to")),

        // Big operators.
        "sum": .init(kind: .symbol(display: "∑", spoken: "sum")),
        "prod": .init(kind: .symbol(display: "∏", spoken: "product")),
        "int": .init(kind: .symbol(display: "∫", spoken: "integral")),
        "oint": .init(kind: .symbol(display: "∮", spoken: "contour integral")),
        "iint": .init(kind: .symbol(display: "∬", spoken: "double integral")),
        "iiint": .init(kind: .symbol(display: "∭", spoken: "triple integral")),

        // Named functions.
        "sin": .init(kind: .function(display: "sin", spoken: "sine")),
        "cos": .init(kind: .function(display: "cos", spoken: "cosine")),
        "tan": .init(kind: .function(display: "tan", spoken: "tangent")),
        "cot": .init(kind: .function(display: "cot", spoken: "cotangent")),
        "sec": .init(kind: .function(display: "sec", spoken: "secant")),
        "csc": .init(kind: .function(display: "csc", spoken: "cosecant")),
        "arcsin": .init(kind: .function(display: "arcsin", spoken: "arc sine")),
        "arccos": .init(kind: .function(display: "arccos", spoken: "arc cosine")),
        "arctan": .init(kind: .function(display: "arctan", spoken: "arc tangent")),
        "sinh": .init(kind: .function(display: "sinh", spoken: "hyperbolic sine")),
        "cosh": .init(kind: .function(display: "cosh", spoken: "hyperbolic cosine")),
        "tanh": .init(kind: .function(display: "tanh", spoken: "hyperbolic tangent")),
        "log": .init(kind: .function(display: "log", spoken: "log")),
        "ln": .init(kind: .function(display: "ln", spoken: "natural log")),
        "lg": .init(kind: .function(display: "lg", spoken: "log base ten")),
        "exp": .init(kind: .function(display: "exp", spoken: "e to the x")),
        "lim": .init(kind: .function(display: "lim", spoken: "limit")),
        "max": .init(kind: .function(display: "max", spoken: "maximum")),
        "min": .init(kind: .function(display: "min", spoken: "minimum")),
        "det": .init(kind: .function(display: "det", spoken: "determinant")),
        "dim": .init(kind: .function(display: "dim", spoken: "dimension")),
        "ker": .init(kind: .function(display: "ker", spoken: "kernel")),
        "deg": .init(kind: .function(display: "deg", spoken: "degrees")),
        "gcd": .init(kind: .function(display: "gcd", spoken: "greatest common divisor")),
        "hom": .init(kind: .function(display: "hom", spoken: "homomorphism")),
        "arg": .init(kind: .function(display: "arg", spoken: "argument")),
        "Pr": .init(kind: .function(display: "Pr", spoken: "probability")),

        // Constants and misc symbols.
        "infty": .init(kind: .symbol(display: "∞", spoken: "infinity")),
        "infin": .init(kind: .symbol(display: "∞", spoken: "infinity")),
        "partial": .init(kind: .symbol(display: "∂", spoken: "partial")),
        "nabla": .init(kind: .symbol(display: "∇", spoken: "nabla")),
        "aleph": .init(kind: .symbol(display: "ℵ", spoken: "aleph")),
        "hbar": .init(kind: .symbol(display: "ℏ", spoken: "h bar")),
        "ell": .init(kind: .symbol(display: "ℓ", spoken: "ell")),
        "imath": .init(kind: .symbol(display: "ℹ", spoken: "imaginary part")),
        "jmath": .init(kind: .symbol(display: "ℼ", spoken: "imaginary part")),
        "Re": .init(kind: .symbol(display: "ℜ", spoken: "real part")),
        "Im": .init(kind: .symbol(display: "ℑ", spoken: "imaginary part")),
        "wp": .init(kind: .symbol(display: "℘", spoken: "Weierstrass p")),
        "angle": .init(kind: .symbol(display: "∠", spoken: "angle")),
        "triangle": .init(kind: .symbol(display: "△", spoken: "triangle")),
        "square": .init(kind: .symbol(display: "□", spoken: "square")),
        "neg": .init(kind: .symbol(display: "¬", spoken: "not")),
        "lnot": .init(kind: .symbol(display: "¬", spoken: "not")),
        "emptyset": .init(kind: .symbol(display: "∅", spoken: "the empty set")),
        "varnothing": .init(kind: .symbol(display: "∅", spoken: "the empty set")),
        "forall": .init(kind: .symbol(display: "∀", spoken: "for all")),
        "exists": .init(kind: .symbol(display: "∃", spoken: "there exists")),
        "prime": .init(kind: .symbol(display: "′", spoken: "prime")),
        "top": .init(kind: .symbol(display: "⊤", spoken: "top")),
        "bot": .init(kind: .symbol(display: "⊥", spoken: "bottom")),

        // Dots.
        "ldots": .init(kind: .dots(display: "…")),
        "cdots": .init(kind: .dots(display: "⋯")),
        "dots": .init(kind: .dots(display: "…")),
        "vdots": .init(kind: .dots(display: "⋮")),
        "ddots": .init(kind: .dots(display: "⋱")),
    ]

    /// Commands recognised WITHOUT `$…$` delimiters.
    ///
    /// A bare `\beta` in a note is maths the user expects to see rendered, and
    /// making the user type delimiters around every symbol is how the feature
    /// gets ignored. But a bare command is indistinguishable from a WINDOWS
    /// PATH (`C:\Users\…`), so the undelimited form is deliberately narrow:
    /// GREEK LETTERS and SYMBOLS only.
    ///
    /// The function names (`\sin`, `\log`, `\max`…) are excluded because
    /// those are also plausible path segments, and a note that says
    /// `C:\Users\max` must not have its path silently rewritten into
    /// "C:Usersmaximum". Anything with an argument (`\frac`, `\sqrt`,
    /// `\text`) needs the delimiters anyway — it cannot be recognised bare
    /// without swallowing the rest of the sentence.
    static let bareAllowed: Set<String> = Set(commands.keys).subtracting([
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan",
        "sinh", "cosh", "tanh", "log", "ln", "lg", "exp", "lim", "max", "min",
        "det", "dim", "ker", "deg", "gcd", "hom", "arg", "Pr",
    ])
}
