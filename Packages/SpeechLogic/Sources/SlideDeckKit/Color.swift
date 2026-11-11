// Color.swift — sRGB colours, theme colour slots and DrawingML-style colour
// transforms (tint, shade, luminance modulation/offset, alpha…), so
// theme-relative colours resolve the way presentation files expect.
//
// Ported from DeckCraft's color crate (github.com/storytold/deckcraft
// @ a0eeb34, MIT/Apache-2.0). The colour-picker grid (`theme_variants`), the
// standard-colours row and the 190-name preset enumeration are editor-side
// surface and are not ported; the read path uses `preset(name)` only.

import Foundation

/// An sRGB colour with straight alpha, components 0–255.
public struct Rgba: Equatable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = Rgba(r: 0, g: 0, b: 0)
    public static let white = Rgba(r: 255, g: 255, b: 255)
    public static let transparent = Rgba(r: 0, g: 0, b: 0, a: 0)

    /// `RRGGBB` or `#RRGGBB` (also `RRGGBBAA`, and the 3-digit shorthand).
    public static func fromHex(_ raw: String) -> Rgba? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }), !s.isEmpty else { return nil }
        func byte(_ i: Int) -> UInt8? {
            guard s.count >= i + 2 else { return nil }
            let start = s.index(s.startIndex, offsetBy: i)
            let end = s.index(start, offsetBy: 2)
            return UInt8(s[start..<end], radix: 16)
        }
        func nibble(_ i: Int) -> UInt8? {
            guard s.count >= i + 1 else { return nil }
            let idx = s.index(s.startIndex, offsetBy: i)
            guard let v = UInt8(String(s[idx]), radix: 16) else { return nil }
            return v * 17
        }
        switch s.count {
        case 6:
            guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
            return Rgba(r: r, g: g, b: b)
        case 8:
            guard let r = byte(0), let g = byte(2), let b = byte(4), let a = byte(6) else { return nil }
            return Rgba(r: r, g: g, b: b, a: a)
        case 3:
            guard let r = nibble(0), let g = nibble(1), let b = nibble(2) else { return nil }
            return Rgba(r: r, g: g, b: b)
        default:
            return nil
        }
    }

    /// `RRGGBB` uppercase (no alpha).
    public var hex: String {
        String(format: "%02X%02X%02X", r, g, b)
    }

    public func withAlpha(_ a: UInt8) -> Rgba {
        Rgba(r: r, g: g, b: b, a: a)
    }

    public func toF32() -> [Float] {
        [Float(r) / 255.0, Float(g) / 255.0, Float(b) / 255.0, Float(a) / 255.0]
    }

    public static func fromF64(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Rgba {
        func c(_ v: Double) -> UInt8 {
            guard v.isFinite else { return 0 }
            return UInt8((min(1.0, max(0.0, v)) * 255.0).rounded())
        }
        return Rgba(r: c(r), g: c(g), b: c(b), a: c(a))
    }

    /// Relative luminance (WCAG), 0–1.
    public func luminance() -> Double {
        func lin(_ c: UInt8) -> Double {
            let v = Double(c) / 255.0
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio between two colours (1–21).
    public func contrast(_ other: Rgba) -> Double {
        let a = luminance(), b = other.luminance()
        let (hi, lo) = a > b ? (a, b) : (b, a)
        return (hi + 0.05) / (lo + 0.05)
    }

    public func toHSL() -> (h: Double, s: Double, l: Double) {
        let r = Double(self.r) / 255.0
        let g = Double(self.g) / 255.0
        let b = Double(self.b) / 255.0
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let l = (maxC + minC) / 2.0
        if abs(maxC - minC) < 1e-12 {
            return (0.0, 0.0, l)
        }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2.0 - maxC - minC) : d / (maxC + minC)
        let h: Double
        if abs(maxC - r) < 1e-12 {
            h = (g - b) / d + (g < b ? 6.0 : 0.0)
        } else if abs(maxC - g) < 1e-12 {
            h = (b - r) / d + 2.0
        } else {
            h = (r - g) / d + 4.0
        }
        return (h * 60.0, s, l)
    }

    public static func fromHSL(_ h: Double, _ s: Double, _ l: Double, _ a: UInt8) -> Rgba {
        let h = ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0)
            .truncatingRemainder(dividingBy: 360.0) / 360.0
        let s = min(1.0, max(0.0, s))
        let l = min(1.0, max(0.0, l))
        if s == 0.0 {
            return fromF64(l, l, l, Double(a) / 255.0)
        }
        let q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
        let p = 2.0 * l - q
        func f(_ tIn: Double) -> Double {
            var t = tIn
            if t < 0.0 { t += 1.0 } else if t > 1.0 { t -= 1.0 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
            return p
        }
        return fromF64(f(h + 1.0 / 3.0), f(h), f(h - 1.0 / 3.0), Double(a) / 255.0)
    }

    /// Linear interpolation (straight alpha).
    public func lerp(_ o: Rgba, _ t: Double) -> Rgba {
        let t = t.isFinite ? min(1.0, max(0.0, t)) : 0.0
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 {
            let v = (Double(a) + (Double(b) - Double(a)) * t).rounded()
            return UInt8(min(255.0, max(0.0, v)))
        }
        return Rgba(r: m(r, o.r), g: m(g, o.g), b: m(b, o.b), a: m(a, o.a))
    }
}

/// The twelve theme colour slots, plus the mapped aliases (`bg1`, `tx1`…)
/// and `phClr` (the placeholder colour a style matrix entry is applied with).
public enum SchemeSlot: String, CaseIterable, Sendable {
    case dk1, lt1, dk2, lt2
    case accent1, accent2, accent3, accent4, accent5, accent6
    case hlink, folHlink
    case bg1, tx1, bg2, tx2
    case phClr

    /// The twelve theme slots, in scheme order.
    public static let theme: [SchemeSlot] = [
        .dk1, .lt1, .dk2, .lt2,
        .accent1, .accent2, .accent3, .accent4, .accent5, .accent6,
        .hlink, .folHlink,
    ]

    /// The raw XML value the slot is written as.
    public var xmlName: String { rawValue }

    public static func fromXML(_ s: String) -> SchemeSlot? {
        SchemeSlot(rawValue: s)
    }
}

/// One colour transform, in file units (percentages ×1000, angles ×60000),
/// applied in order.
public enum ColorTransform: Equatable, Sendable {
    case tint(Int32)
    case shade(Int32)
    case lumMod(Int32)
    case lumOff(Int32)
    case satMod(Int32)
    case satOff(Int32)
    case hueMod(Int32)
    case hueOff(Int32)
    case alpha(Int32)
    case alphaMod(Int32)
    case alphaOff(Int32)
    case comp
    case inv
    case gray
    case redMod(Int32)
    case greenMod(Int32)
    case blueMod(Int32)

    public var xmlName: String {
        switch self {
        case .tint: return "tint"
        case .shade: return "shade"
        case .lumMod: return "lumMod"
        case .lumOff: return "lumOff"
        case .satMod: return "satMod"
        case .satOff: return "satOff"
        case .hueMod: return "hueMod"
        case .hueOff: return "hueOff"
        case .alpha: return "alpha"
        case .alphaMod: return "alphaMod"
        case .alphaOff: return "alphaOff"
        case .comp: return "comp"
        case .inv: return "inv"
        case .gray: return "gray"
        case .redMod: return "redMod"
        case .greenMod: return "greenMod"
        case .blueMod: return "blueMod"
        }
    }

    public var value: Int32? {
        switch self {
        case .tint(let v), .shade(let v), .lumMod(let v), .lumOff(let v),
             .satMod(let v), .satOff(let v), .hueMod(let v), .hueOff(let v),
             .alpha(let v), .alphaMod(let v), .alphaOff(let v),
             .redMod(let v), .greenMod(let v), .blueMod(let v):
            return v
        case .comp, .inv, .gray:
            return nil
        }
    }

    public static func fromXML(_ name: String, _ val: Int32?) -> ColorTransform? {
        let v = val ?? 0
        switch name {
        case "tint": return .tint(v)
        case "shade": return .shade(v)
        case "lumMod": return .lumMod(v)
        case "lumOff": return .lumOff(v)
        case "satMod": return .satMod(v)
        case "satOff": return .satOff(v)
        case "hueMod": return .hueMod(v)
        case "hueOff": return .hueOff(v)
        case "alpha": return .alpha(v)
        case "alphaMod": return .alphaMod(v)
        case "alphaOff": return .alphaOff(v)
        case "comp": return .comp
        case "inv": return .inv
        case "gray": return .gray
        case "redMod": return .redMod(v)
        case "greenMod": return .greenMod(v)
        case "blueMod": return .blueMod(v)
        default: return nil
        }
    }
}

/// Apply transforms to a base colour, in order.
public func colorApply(_ base: Rgba, _ transforms: [ColorTransform]) -> Rgba {
    var c = base
    for t in transforms {
        c = applyOne(c, t)
    }
    return c
}

private func pct(_ v: Int32) -> Double {
    Double(v) / 100_000.0
}

private func applyOne(_ c: Rgba, _ t: ColorTransform) -> Rgba {
    switch t {
    // tint: towards white by (1 - value); shade: towards black by (1 - value).
    // Office applies these in linear light, which keeps mid-tones from
    // washing out.
    case .tint(let v):
        let k = min(1.0, max(0.0, pct(v)))
        return mapLinear(c) { $0 * k + (1.0 - k) }
    case .shade(let v):
        let k = min(1.0, max(0.0, pct(v)))
        return mapLinear(c) { $0 * k }
    case .lumMod(let v):
        let (h, s, l) = c.toHSL()
        return Rgba.fromHSL(h, s, l * pct(v), c.a)
    case .lumOff(let v):
        let (h, s, l) = c.toHSL()
        return Rgba.fromHSL(h, s, l + pct(v), c.a)
    case .satMod(let v):
        let (h, s, l) = c.toHSL()
        return Rgba.fromHSL(h, s * pct(v), l, c.a)
    case .satOff(let v):
        let (h, s, l) = c.toHSL()
        return Rgba.fromHSL(h, s + pct(v), l, c.a)
    case .hueMod(let v):
        let (h, s, l) = c.toHSL()
        return Rgba.fromHSL(h * pct(v), s, l, c.a)
    case .hueOff(let v):
        let (h, s, l) = c.toHSL()
        return Rgba.fromHSL(h + Double(v) / 60_000.0, s, l, c.a)
    case .alpha(let v):
        return c.withAlpha(UInt8((min(1.0, max(0.0, pct(v))) * 255.0).rounded()))
    case .alphaMod(let v):
        return c.withAlpha(UInt8(min(255.0, max(0.0, (Double(c.a) * pct(v)).rounded()))))
    case .alphaOff(let v):
        return c.withAlpha(UInt8(min(255.0, max(0.0, (Double(c.a) + pct(v) * 255.0).rounded()))))
    case .comp:
        let (h, s, l) = c.toHSL()
        return Rgba.fromHSL(h + 180.0, s, l, c.a)
    case .inv:
        return Rgba(r: 255 - c.r, g: 255 - c.g, b: 255 - c.b, a: c.a)
    case .gray:
        let y = (0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)).rounded()
        let g = UInt8(min(255.0, max(0.0, y)))
        return Rgba(r: g, g: g, b: g, a: c.a)
    case .redMod(let v):
        return Rgba(r: UInt8(min(255.0, max(0.0, (Double(c.r) * pct(v)).rounded()))), g: c.g, b: c.b, a: c.a)
    case .greenMod(let v):
        return Rgba(r: c.r, g: UInt8(min(255.0, max(0.0, (Double(c.g) * pct(v)).rounded()))), b: c.b, a: c.a)
    case .blueMod(let v):
        return Rgba(r: c.r, g: c.g, b: UInt8(min(255.0, max(0.0, (Double(c.b) * pct(v)).rounded()))), a: c.a)
    }
}

private func toLin(_ v: UInt8) -> Double {
    let v = Double(v) / 255.0
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private func fromLin(_ vIn: Double) -> Double {
    let v = min(1.0, max(0.0, vIn))
    return v <= 0.003_130_8 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055
}

private func mapLinear(_ c: Rgba, _ f: (Double) -> Double) -> Rgba {
    Rgba.fromF64(fromLin(f(toLin(c.r))), fromLin(f(toLin(c.g))), fromLin(f(toLin(c.b))), Double(c.a) / 255.0)
}

/// A few CSS-like preset colour names (`prstClr`).
public func presetColor(_ name: String) -> Rgba? {
    let c: (UInt8, UInt8, UInt8)
    switch name {
    case "black": c = (0, 0, 0)
    case "white": c = (255, 255, 255)
    case "red": c = (255, 0, 0)
    case "green": c = (0, 128, 0)
    case "lime": c = (0, 255, 0)
    case "blue": c = (0, 0, 255)
    case "yellow": c = (255, 255, 0)
    case "cyan", "aqua": c = (0, 255, 255)
    case "magenta", "fuchsia": c = (255, 0, 255)
    case "gray", "grey": c = (128, 128, 128)
    case "silver": c = (192, 192, 192)
    case "maroon": c = (128, 0, 0)
    case "navy": c = (0, 0, 128)
    case "olive": c = (128, 128, 0)
    case "purple": c = (128, 0, 128)
    case "teal": c = (0, 128, 128)
    case "orange": c = (255, 165, 0)
    case "pink": c = (255, 192, 203)
    case "brown": c = (165, 42, 42)
    case "gold": c = (255, 215, 0)
    case "ltGray", "lightGray": c = (211, 211, 211)
    case "dkGray", "darkGray": c = (169, 169, 169)
    default: return nil
    }
    return Rgba(r: c.0, g: c.1, b: c.2)
}
