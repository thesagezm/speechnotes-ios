// SymbolFonts.swift — symbol-font glyph mapping: Wingdings, Webdings, the
// Adobe Symbol font and their kin encode shapes and Greek letters on ASCII
// code points. The fonts do not exist on iOS, so an unmapped bullet renders
// as the raw letter ("l" where PowerPoint shows ●). Map to the Unicode shape
// instead. Ported from deckcraft-text `map_symbol_bullet` @ a0eeb34 (the
// bullet half the Linux reader never wired into its HTML either), with
// Monotype Sorts added — the old .ppt-era decks in this library bullet with
// it, and it carries the Wingdings encoding for the common shapes.

import Foundation

/// The bullet glyph for `c` (`a:buChar`), given the bullet's `a:buFont`
/// typeface. PowerPoint draws only the first character of a longer `buChar`.
public func mapSymbolBullet(_ c: String, _ font: String?) -> String {
    let f = (font ?? "").lowercased()
    let first = c.first ?? "•"
    // A bullet already above the single-byte range is a real Unicode glyph
    // (a "Segoe UI Symbol" bullet, say) — it renders as-is.
    if let v = first.unicodeScalars.first.map({ $0.value }), v > 0xFF, !isPUAGlyph(first) {
        return String(first)
    }
    if f.hasPrefix("webdings") {
        return webdingsShape(first)
    }
    if f.contains("wingdings") || f.contains("symbol") || f.contains("monotype sorts")
        || isPUAGlyph(first) {
        return symbolBullet(first, font: f)
    }
    return String(first)
}

/// The text of a run set in a symbol font, as Unicode the web can render.
/// Runs in Wingdings-family fonts carry shapes on ASCII code points; runs in
/// the Adobe Symbol font carry Greek letters on ASCII (α is 'a'…). Real
/// Unicode text passes through untouched.
public func mapSymbolText(_ text: String, _ font: String) -> String {
    let f = font.lowercased()
    if f.hasPrefix("webdings") {
        return text.map { webdingsShape($0) }.joined()
    }
    if f.contains("wingdings") || f.contains("monotype sorts") {
        return text.map { wingdingsShape($0) }.joined()
    }
    // The Adobe Symbol font ALONE — "Segoe UI Symbol" and friends carry real
    // Unicode glyphs and must pass through untouched.
    if f == "symbol" {
        return text.map { symbolGreek($0) }.joined()
    }
    return text
}

// ---------------------------------------------------------------------------

/// A single-byte code point (symbol fonts draw on ASCII; anything above 0xFF
/// is already real Unicode and stays). The private-use spelling of a glyph
/// (U+F06C = Wingdings 'l') masks back to its low byte, like upstream's
/// `& 0xff`.
private func byte(_ c: Character) -> Int? {
    let v = c.unicodeScalars.first.map { $0.value } ?? 0
    if (0xF000...0xF0FF).contains(v) { return Int(v - 0xF000) }
    return v <= 0xFF ? Int(v) : nil
}

/// The private-use range PowerPoint uses for symbol glyphs with the font
/// left to the viewer.
private func isPUAGlyph(_ c: Character) -> Bool {
    let v = c.unicodeScalars.first.map { $0.value } ?? 0
    return (0xF000...0xF0FF).contains(v)
}

private func webdingsShape(_ c: Character) -> String {
    switch byte(c) ?? -1 {
    case 0x6e: return "●"
    case 0x67: return "■"
    case 0x61: return "✓"
    case 0x72: return "✕"
    case 0x33: return "◀"
    case 0x34: return "▶"
    case 0x35: return "▲"
    case 0x36: return "▼"
    default: return "•"
    }
}

/// The bullet table: Wingdings/Wingdings 2/Wingdings 3 codes, from
/// deckcraft-text. Monotype Sorts rides the plain-Wingdings branch.
private func symbolBullet(_ c: Character, font: String) -> String {
    let code = byte(c) ?? -1
    if font.hasPrefix("wingdings 2") {
        switch code {
        case 0x97, 0x98: return "●"
        case 0x9e...0xa1: return "■"
        case 0xa2...0xa5: return "◆"
        case 0xea...0xf3: return "★"
        case 0xb7...0xbf: return "○"
        case 0x50: return "✓"
        default: return "•"
        }
    }
    if font.hasPrefix("wingdings 3") {
        switch code {
        case 0x7d, 0x75: return "►"
        case 0x7c, 0x74: return "◄"
        case 0x70: return "▲"
        case 0x71: return "▼"
        case 0xc6, 0xc7: return "➔"
        default: return "▶"
        }
    }
    return wingdingsShape(c)
}

/// Plain Wingdings shapes (and Monotype Sorts' common ones).
private func wingdingsShape(_ c: Character) -> String {
    switch byte(c) ?? -1 {
    case 0x6c: return "●"
    case 0x6e: return "■"
    case 0x75: return "◆"
    case 0x76: return "❖"
    case 0x71: return "❑"
    case 0xa7: return "▪"
    case 0xa8: return "◆"
    case 0xb7: return "•"
    case 0xd8: return "➢"
    case 0xfc: return "✓"
    case 0x2d: return "–"
    case 0x4a: return "☺" // Wingdings 'J' — the smiley every old deck uses
    case 0x4b: return "😐"
    case 0x4c: return "☹"
    default: return "•"
    }
}

/// The Adobe Symbol font's Greek letters and the safe math marks.
private func symbolGreek(_ c: Character) -> String {
    switch c {
    case "a": return "α"
    case "b": return "β"
    case "c": return "χ"
    case "d": return "δ"
    case "e": return "ε"
    case "f": return "φ"
    case "g": return "γ"
    case "h": return "η"
    case "i": return "ι"
    case "j": return "ϕ"
    case "k": return "κ"
    case "l": return "λ"
    case "m": return "μ"
    case "n": return "ν"
    case "o": return "ο"
    case "p": return "π"
    case "q": return "θ"
    case "r": return "ρ"
    case "s": return "σ"
    case "t": return "τ"
    case "u": return "υ"
    case "v": return "ς"
    case "w": return "ω"
    case "x": return "ξ"
    case "y": return "ψ"
    case "z": return "ζ"
    case "A": return "Α"
    case "B": return "Β"
    case "C": return "Χ"
    case "D": return "Δ"
    case "E": return "Ε"
    case "F": return "Φ"
    case "G": return "Γ"
    case "H": return "Η"
    case "J": return "ϑ"
    case "K": return "Κ"
    case "L": return "Λ"
    case "M": return "Μ"
    case "N": return "Ν"
    case "O": return "Ο"
    case "P": return "Π"
    case "Q": return "Θ"
    case "R": return "Ρ"
    case "S": return "Σ"
    case "T": return "Τ"
    case "U": return "Υ"
    case "V": return "ς"
    case "W": return "Ω"
    case "X": return "Ξ"
    case "Y": return "Ψ"
    case "Z": return "Ζ"
    case "\u{A5}": return "∞"
    case "\u{BB}": return "≈"
    case "\u{B9}": return "≥"
    default: return String(c)
    }
}
