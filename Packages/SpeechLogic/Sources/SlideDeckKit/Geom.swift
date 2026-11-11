// Geom.swift — points, rects, affines, paths, EMU units and shape transforms.
//
// Ported from DeckCraft's geom crate `lib.rs` (github.com/storytold/deckcraft
// @ a0eeb34, MIT/Apache-2.0), read-path subset: the editor-only helpers
// (display units, hit testing, snapping, the morph/squircle/warp animation
// modules) are not ported. What the deck stack actually consumes is EMU↔pt,
// `Xfrm` (offset, extent, rotation, flips — with rotation about the centre)
// and the group child-space mapping, all here.
//
// The primitive types stand in for kurbo's Point/Vec2/Rect/Size/Affine with
// the same semantics (a `D` prefix keeps them unambiguous next to
// Foundation/CoreGraphics in app code). kurbo's Arc→cubic approximation is
// ported bit-for-bit from kurbo 0.13.1 (the version DeckCraft pins), so the
// emitted control points match the reference renders exactly.

import Foundation

// MARK: - EMU units

/// EMU per point.
public let emuPerPt: Double = 12_700.0
/// EMU per inch.
public let emuPerIn: Double = 914_400.0
/// EMU per centimetre.
public let emuPerCm: Double = 360_000.0

public func emuToPt(_ emu: Int64) -> Double {
    Double(emu) / emuPerPt
}

/// Points to EMU, rounded. Non-finite input becomes 0; huge values saturate.
public func ptToEmu(_ pt: Double) -> Int64 {
    guard pt.isFinite else { return 0 }
    let v = (pt * emuPerPt).rounded()
    if v >= Double(Int64.max) { return Int64.max }
    if v <= Double(Int64.min) { return Int64.min }
    return Int64(v)
}

// MARK: - primitives (kurbo stand-ins)

/// A point (kurbo `Point`).
public struct DPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = DPoint(x: 0, y: 0)

    public static func + (p: DPoint, v: DVec) -> DPoint { DPoint(x: p.x + v.dx, y: p.y + v.dy) }
    public static func - (p: DPoint, v: DVec) -> DPoint { DPoint(x: p.x - v.dx, y: p.y - v.dy) }
    /// Point difference as a vector (kurbo `Point - Point`).
    public static func - (a: DPoint, b: DPoint) -> DVec { DVec(dx: a.x - b.x, dy: a.y - b.y) }

    public func dist(_ o: DPoint) -> Double {
        (self - o).hypot()
    }
}

/// A vector (kurbo `Vec2`) — a difference, scaled and rotated but not translated.
public struct DVec: Equatable, Sendable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public init(from p: DPoint) {
        dx = p.x
        dy = p.y
    }

    public static let zero = DVec(dx: 0, dy: 0)

    public static func + (a: DVec, b: DVec) -> DVec { DVec(dx: a.dx + b.dx, dy: a.dy + b.dy) }
    public static func - (a: DVec, b: DVec) -> DVec { DVec(dx: a.dx - b.dx, dy: a.dy - b.dy) }
    public static func - (v: DVec) -> DVec { DVec(dx: -v.dx, dy: -v.dy) }
    public static func * (v: DVec, k: Double) -> DVec { DVec(dx: v.dx * k, dy: v.dy * k) }
    public static func / (v: DVec, k: Double) -> DVec { DVec(dx: v.dx / k, dy: v.dy / k) }

    public var hypot2: Double { dx * dx + dy * dy }
    public var hypot: Double { (dx * dx + dy * dy).squareRoot() }
    public func dot(_ o: DVec) -> Double { dx * o.dx + dy * o.dy }

    /// Unit length (the Rust code divides by `hypot` only after checking it).
    public func normalized() -> DVec {
        let h = hypot
        return h > 0 ? self / h : DVec.zero
    }

    public var point: DPoint { DPoint(x: dx, y: dy) }
}

/// Axis-aligned rectangle by its edges (kurbo `Rect`: x0 ≤ x1 after `abs`).
public struct DRect: Equatable, Sendable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public static let zero = DRect(x0: 0, y0: 0, x1: 0, y1: 0)

    /// The unit box every preset is built over.
    public static func new(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> DRect {
        DRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// The bounding box of the two points.
    public static func fromPoints(_ a: DPoint, _ b: DPoint) -> DRect {
        DRect(x0: min(a.x, b.x), y0: min(a.y, b.y), x1: max(a.x, b.x), y1: max(a.y, b.y))
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
    public var origin: DPoint { DPoint(x: x0, y: y0) }

    /// Edges sorted so x0 ≤ x1 and y0 ≤ y1 (kurbo `Rect::abs`).
    public func abs() -> DRect {
        DRect(x0: min(x0, x1), y0: min(y0, y1), x1: max(x0, x1), y1: max(y0, y1))
    }

    /// Grow (negative inset) or shrink each side by `d` (kurbo `Rect::inset`).
    public func inset(_ d: Double) -> DRect {
        DRect(x0: x0 + d, y0: y0 + d, x1: x1 - d, y1: y1 - d)
    }

    public func unionPt(_ p: DPoint) -> DRect {
        DRect(x0: min(x0, p.x), y0: min(y0, p.y), x1: max(x1, p.x), y1: max(y1, p.y))
    }
}

/// Width and height (kurbo `Size`).
public struct DSize: Equatable, Sendable {
    public var w: Double
    public var h: Double
    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

/// A 2-D affine transform, stored as kurbo does: `[a, b, c, d, e, f]` meaning
/// x' = a·x + c·y + e, y' = b·x + d·y + f.
public struct DAffine: Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var e: Double
    public var f: Double

    public init(_ m: [Double]) {
        precondition(m.count == 6)
        a = m[0]; b = m[1]; c = m[2]; d = m[3]; e = m[4]; f = m[5]
    }

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public static let identity = DAffine(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    public static func translate(_ v: DVec) -> DAffine {
        DAffine(a: 1, b: 0, c: 0, d: 1, e: v.dx, f: v.dy)
    }

    public static func scale(_ s: Double) -> DAffine {
        DAffine(a: s, b: 0, c: 0, d: s, e: 0, f: 0)
    }

    public static func scaleNonUniform(_ sx: Double, _ sy: Double) -> DAffine {
        DAffine(a: sx, b: 0, c: 0, d: sy, e: 0, f: 0)
    }

    /// Rotation by `theta` radians (kurbo `Affine::rotate`).
    public static func rotate(_ theta: Double) -> DAffine {
        let (s, co) = (sin(theta), cos(theta))
        return DAffine(a: co, b: s, c: -s, d: co, e: 0, f: 0)
    }

    /// Matrix product: `A * B` applies B first, then A.
    public static func * (l: DAffine, r: DAffine) -> DAffine {
        DAffine(
            a: l.a * r.a + l.c * r.b,
            b: l.b * r.a + l.d * r.b,
            c: l.a * r.c + l.c * r.d,
            d: l.b * r.c + l.d * r.d,
            e: l.a * r.e + l.c * r.f + l.e,
            f: l.b * r.e + l.d * r.f + l.f
        )
    }

    public func apply(_ p: DPoint) -> DPoint {
        DPoint(x: a * p.x + c * p.y + e, y: b * p.x + d * p.y + f)
    }

    /// Apply without the translation (kurbo `Affine * Vec2`).
    public func applyVec(_ v: DVec) -> DVec {
        DVec(dx: a * v.dx + c * v.dy, dy: b * v.dx + d * v.dy)
    }

    /// Axis-aligned bounds of the transformed rect (transform its corners).
    public func transformRectBBox(_ r: DRect) -> DRect {
        let c0 = apply(DPoint(x: r.x0, y: r.y0))
        let c1 = apply(DPoint(x: r.x1, y: r.y0))
        let c2 = apply(DPoint(x: r.x1, y: r.y1))
        let c3 = apply(DPoint(x: r.x0, y: r.y1))
        var out = DRect.fromPoints(c0, c1)
        out = out.unionPt(c2).unionPt(c3)
        return out
    }
}

// MARK: - paths

/// One path element, mirroring kurbo's `PathEl`.
public enum PathElement: Equatable, Sendable {
    case move(DPoint)
    case line(DPoint)
    case quad(DPoint, DPoint)
    case cubic(DPoint, DPoint, DPoint)
    case close
}

/// A Bézier path: the geometry a preset shape (or custom path outline) is made of.
public struct GeomPath: Equatable, Sendable {
    public var elements: [PathElement]

    public init() {
        elements = []
    }

    public init(elements: [PathElement]) {
        self.elements = elements
    }

    public mutating func move(_ p: DPoint) { elements.append(.move(p)) }
    public mutating func line(_ p: DPoint) { elements.append(.line(p)) }
    public mutating func quad(_ c: DPoint, _ p: DPoint) { elements.append(.quad(c, p)) }
    public mutating func cubic(_ c1: DPoint, _ c2: DPoint, _ p: DPoint) { elements.append(.cubic(c1, c2, p)) }
    public mutating func close() { elements.append(.close) }

    /// Concatenate another path's elements (kurbo `extend` with an iterator).
    public mutating func extend(_ other: GeomPath) {
        elements.append(contentsOf: other.elements)
    }

    /// The SVG path-data string, in kurbo's exact `to_svg` format (`M{},{} L{},{} … Z`,
    /// single spaces between elements). Numbers print like Rust's `Display`: shortest
    /// round-trip, never scientific notation, integral values without `.0`.
    public func toSVG() -> String {
        var out = ""
        for (i, el) in elements.enumerated() {
            if i > 0 { out += " " }
            switch el {
            case .move(let p):
                out += "M\(svgNum(p.x)),\(svgNum(p.y))"
            case .line(let p):
                out += "L\(svgNum(p.x)),\(svgNum(p.y))"
            case .quad(let c, let p):
                out += "Q\(svgNum(c.x)),\(svgNum(c.y)) \(svgNum(p.x)),\(svgNum(p.y))"
            case .cubic(let c1, let c2, let p):
                out += "C\(svgNum(c1.x)),\(svgNum(c1.y)) \(svgNum(c2.x)),\(svgNum(c2.y)) \(svgNum(p.x)),\(svgNum(p.y))"
            case .close:
                out += "Z"
            }
        }
        return out
    }

    /// Apply an affine transform to every point.
    public mutating func applyAffine(_ t: DAffine) {
        elements = elements.map { el in
            switch el {
            case .move(let p): return .move(t.apply(p))
            case .line(let p): return .line(t.apply(p))
            case .quad(let c, let p): return .quad(t.apply(c), t.apply(p))
            case .cubic(let c1, let c2, let p): return .cubic(t.apply(c1), t.apply(c2), t.apply(p))
            case .close: return .close
            }
        }
    }

    /// A flattened copy (move/line/close only) — the input for bounds, area and
    /// point-on-outline tests.
    public func flattened(tolerance: Double) -> [FlatElement] {
        var out: [FlatElement] = []
        var cur = DPoint.zero
        var start = DPoint.zero
        for el in elements {
            switch el {
            case .move(let p):
                out.append(.move(p))
                cur = p
                start = p
            case .line(let p):
                out.append(.line(cur, p))
                cur = p
            case .quad(let c, let p):
                // Elevate the quadratic to a cubic exactly, then flatten.
                let c1 = DPoint(x: cur.x + (c.x - cur.x) * 2.0 / 3.0, y: cur.y + (c.y - cur.y) * 2.0 / 3.0)
                let c2 = DPoint(x: p.x + (c.x - p.x) * 2.0 / 3.0, y: p.y + (c.y - p.y) * 2.0 / 3.0)
                flattenCubic(cur, c1, c2, p, tolerance: tolerance, cur: &cur, out: &out)
            case .cubic(let c1, let c2, let p):
                flattenCubic(cur, c1, c2, p, tolerance: tolerance, cur: &cur, out: &out)
            case .close:
                out.append(.close(cur, start))
                cur = start
            }
        }
        return out
    }

    /// Recursive de Casteljau flattening: subdivide while either control point sits
    /// more than `tolerance` off the chord (kurbo's `flatten`, classic flatness test).
    private func flattenCubic(_ p0: DPoint, _ p1: DPoint, _ p2: DPoint, _ p3: DPoint, tolerance: Double, cur: inout DPoint, out: inout [FlatElement]) {
        var stack: [(DPoint, DPoint, DPoint, DPoint, Int)] = [(p0, p1, p2, p3, 0)]
        while let (a0, a1, a2, a3, depth) = stack.popLast() {
            let ax = a3.x - a0.x, ay = a3.y - a0.y
            let n2 = ax * ax + ay * ay
            func off(_ q: DPoint) -> Double {
                if n2 < 1e-24 { return q.dist(a0) }
                var t = ((q.x - a0.x) * ax + (q.y - a0.y) * ay) / n2
                t = min(1.0, max(0.0, t))
                return q.dist(DPoint(x: a0.x + ax * t, y: a0.y + ay * t))
            }
            if depth >= 32 || max(off(a1), off(a2)) <= tolerance {
                out.append(.line(cur, a3))
                cur = a3
                continue
            }
            // de Casteljau split at t = 0.5.
            let b01 = DPoint(x: (a0.x + a1.x) / 2, y: (a0.y + a1.y) / 2)
            let b12 = DPoint(x: (a1.x + a2.x) / 2, y: (a1.y + a2.y) / 2)
            let b23 = DPoint(x: (a2.x + a3.x) / 2, y: (a2.y + a3.y) / 2)
            let b012 = DPoint(x: (b01.x + b12.x) / 2, y: (b01.y + b12.y) / 2)
            let b123 = DPoint(x: (b12.x + b23.x) / 2, y: (b12.y + b23.y) / 2)
            let mid = DPoint(x: (b012.x + b123.x) / 2, y: (b012.y + b123.y) / 2)
            // Push the second half first so the first half is processed next (depth-first order).
            stack.append((mid, b123, b23, a3, depth + 1))
            stack.append((a0, b01, b012, mid, depth + 1))
        }
    }

    /// Axis-aligned bounds of the flattened path (kurbo's exact bounds find curve
    /// extrema; every test here checks vertices or allows slack well above the
    /// flattening error).
    public func boundingBox() -> DRect {
        var r: DRect?
        for el in flattened(tolerance: 0.1) {
            switch el {
            case .move(let p): r = r.map { $0.unionPt(p) } ?? DRect.fromPoints(p, p)
            case .line(_, let p): r = r.map { $0.unionPt(p) } ?? DRect.fromPoints(p, p)
            case .close(let last, let start):
                r = r.map { $0.unionPt(last).unionPt(start) } ?? DRect.fromPoints(last, start)
            }
        }
        return r ?? .zero
    }

    /// Signed area (positive wound one way, negative the other; holes subtract),
    /// computed over the flattened outline. Closing segments are boundary edges
    /// and must count — a `poly`'s last vertex usually differs from its first.
    public func area() -> Double {
        var acc = 0.0
        for el in flattened(tolerance: 0.1) {
            switch el {
            case .move: break
            case .line(let a, let b): acc += a.x * b.y - b.x * a.y
            case .close(let last, let start): acc += last.x * start.y - start.x * last.y
            }
        }
        return acc / 2.0
    }
}

/// A flattened path element: moves and chord segments, with closes carrying the
/// subpath start (mirrors what kurbo's `flatten` emits).
public enum FlatElement {
    case move(DPoint)
    case line(DPoint, DPoint)
    case close(DPoint, DPoint)
}

/// Format a double like Rust's `Display` (kurbo's `to_svg` builds its numbers
/// with `write!`): shortest round-trip digits, plain decimal — never scientific
/// notation — and integral values without a trailing `.0`.
func svgNum(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-inf" : "inf" }
    var s = "\(v)"
    if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        let mant = String(s[s.startIndex..<eIdx])
        let exp = Int(s[s.index(after: eIdx)...]) ?? 0
        var digits = mant
        var sign = ""
        if digits.hasPrefix("-") || digits.hasPrefix("+") { sign = String(digits.removeFirst()) }
        if let dot = digits.firstIndex(of: ".") { digits.remove(at: dot) }
        let pointPos = 1 + exp
        if pointPos <= 0 {
            s = sign + "0." + String(repeating: "0", count: -pointPos) + digits
        } else if pointPos >= digits.count {
            s = sign + digits + String(repeating: "0", count: pointPos - digits.count)
        } else {
            let i = digits.index(digits.startIndex, offsetBy: pointPos)
            s = sign + digits[..<i] + "." + digits[i...]
        }
    }
    if s.hasSuffix(".0") { s.removeLast(2) }
    return s
}

// MARK: - elliptic arcs (kurbo 0.13.1, bit-for-bit)

/// Samples the axis-aligned ellipse of radii `r` at parametric `angle` radians
/// (kurbo `sample_ellipse`, x_rotation 0 — every DeckCraft call site uses 0).
private func sampleEllipse(_ rx: Double, _ ry: Double, _ angle: Double) -> DVec {
    DVec(dx: rx * cos(angle), dy: ry * sin(angle))
}

/// Emit cubic Bézier segments approximating an elliptic arc, exactly as kurbo
/// 0.13.1's `Arc::to_cubic_beziers(tolerance)` does: segment count from the
/// error formula, arm length from the segment angle's tangent quarter.
func arcToCubics(center: DPoint, rx: Double, ry: Double, startAngle: Double, sweepAngle: Double, tolerance: Double, into path: inout GeomPath) {
    let sign: Double = sweepAngle < 0 ? -1.0 : 1.0
    let scaledErr = max(rx, ry) / tolerance
    // Number of subdivisions per ellipse based on error tolerance (kurbo:
    // slightly underestimates the error for quadrants).
    let nErr = max(pow(1.1163 * scaledErr, 1.0 / 6.0), 3.999_999)
    var n = (nErr * abs(sweepAngle) * (1.0 / (2.0 * .pi))).rounded(.up)
    if n < 1 { n = 0 }
    let angleStep = n > 0 ? sweepAngle / n : 0
    let armLen = (4.0 / 3.0) * tan(abs(0.25 * angleStep)) * sign
    var angle0 = startAngle
    var p0 = sampleEllipse(rx, ry, angle0)
    // Kurbo has no cap; a cap only matters for absurd radii (hostile input),
    // where a multi-million-segment loop would hang the viewer.
    for _ in 0..<Int(min(n, 100_000)) {
        let angle1 = angle0 + angleStep
        let p1 = p0 + armLen * sampleEllipse(rx, ry, angle0 + .pi / 2)
        let p3 = sampleEllipse(rx, ry, angle1)
        let p2 = p3 - armLen * sampleEllipse(rx, ry, angle1 + .pi / 2)
        path.cubic(center + p1, center + p2, center + p3)
        angle0 = angle1
        p0 = p3
    }
}

// MARK: - shape transforms (geom lib.rs)

/// A shape's placement on its slide (or in its group's child space): offset, extent, rotation
/// (degrees clockwise) and flips. Rotation and flips are about the centre.
public struct Xfrm: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var rot: Double
    public var flipH: Bool
    public var flipV: Bool

    public init(x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0, rot: Double = 0, flipH: Bool = false, flipV: Bool = false) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.rot = rot
        self.flipH = flipH
        self.flipV = flipV
    }

    public func rect() -> DRect {
        DRect(x0: x, y0: y, x1: x + w, y1: y + h)
    }

    public func center() -> DPoint {
        DPoint(x: x + w / 2.0, y: y + h / 2.0)
    }

    /// Local shape space (0..w, 0..h) → parent space, applying flips and rotation about the centre.
    public func affine() -> DAffine {
        let c = DVec(dx: w / 2.0, dy: h / 2.0)
        let sx: Double = flipH ? -1.0 : 1.0
        let sy: Double = flipV ? -1.0 : 1.0
        return DAffine.translate(DVec(dx: x, dy: y) + c)
            * DAffine.rotate(rot.toRadians)
            * DAffine.scaleNonUniform(sx, sy)
            * DAffine.translate(-c)
    }

    /// Axis-aligned bounds of the rotated box in parent space.
    public func bounds() -> DRect {
        let t = affine()
        let pts = [DPoint(x: 0, y: 0), DPoint(x: w, y: 0), DPoint(x: w, y: h), DPoint(x: 0, y: h)].map { t.apply($0) }
        var r = DRect.fromPoints(pts[0], pts[1])
        r = r.unionPt(pts[2]).unionPt(pts[3])
        return r
    }

    /// True when no dimension is NaN/inf.
    public var isFinite: Bool {
        [x, y, w, h, rot].allSatisfy { $0.isFinite }
    }

    /// Rotation normalised to 0..360.
    public var rotNorm: Double {
        let r = rot.truncatingRemainder(dividingBy: 360.0)
        return r < 0.0 ? r + 360.0 : r
    }
}

/// Maps a group's child coordinate space (`chOff`, `chExt`) onto the group's own box.
public func groupChildAffine(group: Xfrm, ch: DRect) -> DAffine {
    let sx = abs(ch.width) > 1e-9 ? group.w / ch.width : 1.0
    let sy = abs(ch.height) > 1e-9 ? group.h / ch.height : 1.0
        return group.affine() * DAffine.scaleNonUniform(sx, sy) * DAffine.translate(-DVec(from: ch.origin))
}

// MARK: - angle helpers

extension Double {
    /// Degrees to radians (`to_radians` in Rust). Not named `radians` — that
    /// collides with Foundation's `Double.radians -> Angle` (iOS 16+).
    var toRadians: Double { self * .pi / 180.0 }
    /// Radians to degrees (`to_degrees` in Rust).
    var toDegrees: Double { self * 180.0 / .pi }
}

/// Clamp like Rust's `f64::clamp` (no panic path here; NaN passes through).
func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    if v < lo { return lo }
    if v > hi { return hi }
    return v
}

/// Rust's `rem_euclid`: the remainder in 0..<m for m > 0.
func remEuclid(_ a: Double, _ m: Double) -> Double {
    let r = a.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + m.abs() : r
}
