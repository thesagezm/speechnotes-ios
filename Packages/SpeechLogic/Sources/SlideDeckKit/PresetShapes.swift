// PresetShapes.swift — the preset shape builder.
//
// Ported from DeckCraft's geom crate `preset.rs` (github.com/storytold/deckcraft
// @ a0eeb34, MIT/Apache-2.0): the `Pb` path builder, the geometry helpers
// (`vis`, `polygon_regular`, `normalize`, `star`, `corner_rect`, the arrow
// construction, `cloud`, the equation shapes, ribbons, scrolls, action
// buttons) and the whole `build()` switch. Every outline is DeckCraft's own
// construction re-derived from what the shapes look like and what their adjust
// values mean (see the Rust header) — the file's comments are kept where they
// explain a shape decision.
//
// Dropped as editor-only: `Handle` (the draggable adjust handles) and the
// connector glue `sites`; arms that only pushed handles reduce to the plain
// geometry.

import Foundation

// MARK: - path builder

/// The fluent path builder the preset outlines are written with
/// (`Pb` in the Rust source). A class so the `b.m(..).l(..)` chains mutate it.
final class Pb {
    private(set) var path = GeomPath()
    /// The current point; `arc` continues from it.
    var cur = DPoint.zero

    @discardableResult
    func m(_ x: Double, _ y: Double) -> Pb {
        cur = DPoint(x: x, y: y)
        path.move(cur)
        return self
    }

    @discardableResult
    func l(_ x: Double, _ y: Double) -> Pb {
        cur = DPoint(x: x, y: y)
        path.line(cur)
        return self
    }

    @discardableResult
    func c(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) -> Pb {
        cur = DPoint(x: x, y: y)
        path.cubic(DPoint(x: x1, y: y1), DPoint(x: x2, y: y2), cur)
        return self
    }

    @discardableResult
    func q(_ x1: Double, _ y1: Double, _ x: Double, _ y: Double) -> Pb {
        cur = DPoint(x: x, y: y)
        path.quad(DPoint(x: x1, y: y1), cur)
        return self
    }

    /// Elliptic arc continuing from the current point, which lies on the ellipse at parametric
    /// angle `st` (degrees); sweeps `sw` degrees (positive = clockwise on screen).
    @discardableResult
    func arc(_ wr: Double, _ hr: Double, _ st: Double, _ sw: Double) -> Pb {
        let s = st.toRadians
        let e = (st + sw).toRadians
        let center = DPoint(x: cur.x - wr * cos(s), y: cur.y - hr * sin(s))
        arcCubics(center: center, rx: abs(wr), ry: abs(hr), startAngle: s, sweepAngle: e - s, tolerance: 0.05)
        cur = DPoint(x: center.x + wr * cos(e), y: center.y + hr * sin(e))
        return self
    }

    /// Cubics for an arc whose centre is given directly (kurbo `Arc::new` +
    /// `to_cubic_beziers`, used by `arc` and by `moon`'s inner edge).
    func arcCubics(center: DPoint, rx: Double, ry: Double, startAngle: Double, sweepAngle: Double, tolerance: Double) {
        arcToCubics(center: center, rx: rx, ry: ry, startAngle: startAngle, sweepAngle: sweepAngle, tolerance: tolerance, into: &path)
    }

    /// A DrawingML `arcTo`: angles are where the ray from the ellipse's centre at that angle
    /// meets it (not the ellipse's parameter), so elliptical arcs start and end where the
    /// standard's shapes expect.
    @discardableResult
    func arcSpec(_ wr: Double, _ hr: Double, _ st: Double, _ sw: Double) -> Pb {
        func par(_ a: Double) -> Double {
            let r = a.toRadians
            return atan2(wr * sin(r), hr * cos(r))
        }
        let t0 = par(st)
        var d = par(st + sw) - t0
        let tau = 2.0 * Double.pi
        if abs(sw) >= 360.0 {
            d = (sw < 0 || (sw == 0 && sw.sign == .minus)) ? -tau : tau
        } else {
            while sw > 0.0 && d < 0.0 { d += tau }
            while sw < 0.0 && d > 0.0 { d -= tau }
        }
        return arc(wr, hr, t0.toDegrees, d.toDegrees)
    }

    @discardableResult
    func z() -> Pb {
        path.close()
        return self
    }

    @discardableResult
    func poly(_ pts: [(Double, Double)]) -> Pb {
        for (i, p) in pts.enumerated() {
            if i == 0 {
                m(p.0, p.1)
            } else {
                l(p.0, p.1)
            }
        }
        return z()
    }

    @discardableResult
    func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Pb {
        m(cx + rx, cy)
        arc(rx, ry, 0.0, 360.0)
        return z()
    }

    /// The path built so far, resetting the builder (kurbo `std::mem::take`).
    func takePath() -> GeomPath {
        let p = path
        path = GeomPath()
        return p
    }
}

// MARK: - sub-path constructors

func fill(_ p: GeomPath) -> SubPath {
    SubPath(path: p, fill: .norm, stroke: true, evenOdd: false)
}

func fillEO(_ p: GeomPath) -> SubPath {
    SubPath(path: p, fill: .norm, stroke: true, evenOdd: true)
}

func shade(_ p: GeomPath, _ m: FillMode) -> SubPath {
    SubPath(path: p, fill: m, stroke: true, evenOdd: false)
}

func strokeOnly(_ p: GeomPath) -> SubPath {
    SubPath(path: p, fill: .none, stroke: true, evenOdd: false)
}

func fillOnly(_ p: GeomPath) -> SubPath {
    SubPath(path: p, fill: .norm, stroke: false, evenOdd: false)
}

/// A preset geometry with a single sub-path (the common case).
func simple(_ path: GeomPath, _ text: DRect) -> Geometry {
    Geometry(paths: [fill(path)], textRect: text)
}

// MARK: - geometry helpers

/// Parametric angle on an rx×ry ellipse for a visual angle `deg` (file angles are visual).
func vis(_ deg: Double, _ rx: Double, _ ry: Double) -> Double {
    let t = deg.toRadians
    return atan2(rx * sin(t), ry * cos(t)).toDegrees
}

func polygonRegular(_ n: Int, _ w: Double, _ h: Double, _ phase: Double) -> [(Double, Double)] {
    let pts: [(Double, Double)] = (0..<n).map { i in
        let a = (phase + 360.0 * Double(i) / Double(n)).toRadians
        return (cos(a), sin(a))
    }
    return normalize(pts, w, h)
}

/// Scale `pts` so their bounding box fills 0..w × 0..h.
func normalize(_ pts: [(Double, Double)], _ w: Double, _ h: Double) -> [(Double, Double)] {
    var x0 = Double.greatestFiniteMagnitude, y0 = Double.greatestFiniteMagnitude
    var x1 = -Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
    for (x, y) in pts {
        x0 = min(x0, x)
        y0 = min(y0, y)
        x1 = max(x1, x)
        y1 = max(y1, y)
    }
    let sx = x1 - x0 > 1e-12 ? w / (x1 - x0) : 0.0
    let sy = y1 - y0 > 1e-12 ? h / (y1 - y0) : 0.0
    return pts.map { (($0.0 - x0) * sx, ($0.1 - y0) * sy) }
}

/// An n-pointed star as ECMA-376 draws it: points on an ellipse around (hc, vc · vf) with radii
/// half the box stretched by the preset's `hf` / `vf` (so a five-pointed star fills its box and
/// looks regular in a square), the inner corners `inner` of the way out.
func star(_ n: Int, _ w: Double, _ h: Double, _ inner: Double) -> [(Double, Double)] {
    let hf: Double, vf: Double
    switch n {
    case 5: hf = 1.05146; vf = 1.10557
    case 6: hf = 1.15470; vf = 1.0
    case 7: hf = 1.02572; vf = 1.05210
    case 10: hf = 1.05146; vf = 1.0
    default: hf = 1.0; vf = 1.0
    }
    let (rx, ry, cy) = (w / 2.0 * hf, h / 2.0 * vf, h / 2.0 * vf)
    var pts: [(Double, Double)] = []
    pts.reserveCapacity(n * 2)
    for i in 0..<n * 2 {
        let a = (-90.0 + 180.0 * Double(i) / Double(n)).toRadians
        let r = i % 2 == 0 ? 1.0 : inner
        pts.append((w / 2.0 + r * rx * cos(a), cy + r * ry * sin(a)))
    }
    return pts
}

/// The text rectangle ECMA-376's presetShapeDefinitions give a star (`inner` is the adjust value
/// over 50000), where known: star4's is the square inside its inner points, star5's spans the
/// inner pentagon from its upper side points to its bottom inner point.
func starTextRect(_ n: Int, _ w: Double, _ h: Double, _ inner: Double) -> DRect? {
    let (hc, vc) = (w / 2.0, h / 2.0)
    switch n {
    case 4:
        let (dx, dy) = (hc * inner * cos(45.0.toRadians), vc * inner * sin(45.0.toRadians))
        return DRect(x0: hc - dx, y0: vc - dy, x1: hc + dx, y1: vc + dy)
    case 5:
        let (swd2, shd2, svc) = (hc * 1.05146, vc * 1.10557, vc * 1.10557)
        let (iwd2, ihd2) = (swd2 * inner, shd2 * inner)
        let sdx1 = iwd2 * cos(18.0.toRadians)
        let sdy1 = ihd2 * sin(54.0.toRadians)
        return DRect(x0: hc - sdx1, y0: svc - sdy1, x1: hc + sdx1, y1: svc + ihd2)
    default:
        return nil
    }
}

/// A corner treatment: square, rounded (radius) or snipped (diagonal cut).
enum Corner {
    case square
    case round(Double)
    case snip(Double)
}

/// A rectangle with each corner (TL, TR, BR, BL) square, rounded or snipped.
func cornerRect(_ w: Double, _ h: Double, _ c: [Corner]) -> GeomPath {
    let b = Pb()
    func size(_ k: Corner) -> Double {
        switch k {
        case .square: return 0.0
        case .round(let r), .snip(let r): return max(r, 0.0)
        }
    }
    let s0 = size(c[0])
    b.m(s0, 0.0)
    // top edge → TR
    let s1 = size(c[1])
    b.l(w - s1, 0.0)
    switch c[1] {
    case .round(let r) where r > 0.0:
        b.arc(r, r, 270.0, 90.0)
    case .snip:
        b.l(w, s1)
    default:
        break
    }
    let s2 = size(c[2])
    b.l(w, h - s2)
    switch c[2] {
    case .round(let r) where r > 0.0:
        b.arc(r, r, 0.0, 90.0)
    case .snip:
        b.l(w - s2, h)
    default:
        break
    }
    let s3 = size(c[3])
    b.l(s3, h)
    switch c[3] {
    case .round(let r) where r > 0.0:
        b.arc(r, r, 90.0, 90.0)
    case .snip:
        b.l(0.0, h - s3)
    default:
        break
    }
    b.l(0.0, s0)
    switch c[0] {
    case .round(let r) where r > 0.0:
        b.arc(r, r, 180.0, 90.0)
    case .snip:
        b.l(s0, 0.0)
    default:
        break
    }
    b.z()
    return b.takePath()
}

/// Orientation for single-axis arrows built along +x.
enum ArrowDir {
    case right, left, up, down
}

/// Map canonical (u along the arrow's length L, v across thickness T) to shape space.
func orient(_ d: ArrowDir, _ w: Double, _ h: Double, _ pts: [(Double, Double)]) -> [(Double, Double)] {
    pts.map { u, v in
        switch d {
        case .right: return (u, v)
        case .left: return (w - u, v)
        case .up: return (v, h - u)
        case .down: return (v, u)
        }
    }
}

func lenThick(_ d: ArrowDir, _ w: Double, _ h: Double) -> (Double, Double) {
    switch d {
    case .right, .left: return (w, h)
    case .up, .down: return (h, w)
    }
}

func arrow(_ d: ArrowDir, _ w: Double, _ h: Double, _ a1: Double, _ a2: Double) -> Geometry {
    let (l, t) = lenThick(d, w, h)
    let ss = min(l, t)
    let a1c = clamp(a1, 0.0, 100000.0) / 100000.0
    let dx = min(ss * clamp(a2, 0.0, 100000.0 * l / ss.maximum(1e-9)) / 100000.0, l)
    let y1 = t / 2.0 - t * a1c / 2.0
    let y2 = t / 2.0 + t * a1c / 2.0
    let pts: [(Double, Double)] = [(0.0, y1), (l - dx, y1), (l - dx, 0.0), (l, t / 2.0), (l - dx, t), (l - dx, y2), (0.0, y2)]
    let oriented = orient(d, w, h, pts)
    let tr = orient(d, w, h, [(0.0, y1), (l - dx + dx * (y1 / (t / 2.0).maximum(1e-9)), y2)])
    let text = DRect.fromPoints(DPoint(x: tr[0].0, y: tr[0].1), DPoint(x: tr[1].0, y: tr[1].1)).abs()
    return Geometry(paths: [fill(Pb().poly(oriented).takePath())], textRect: text)
}

func doubleArrow(vertical: Bool, _ w: Double, _ h: Double, _ a1: Double, _ a2: Double) -> Geometry {
    let (l, t) = vertical ? (h, w) : (w, h)
    let ss = min(l, t)
    let a1c = clamp(a1, 0.0, 100000.0) / 100000.0
    let dx = min(ss * max(a2, 0.0) / 100000.0, l / 2.0)
    let y1 = t / 2.0 - t * a1c / 2.0
    let y2 = t / 2.0 + t * a1c / 2.0
    let pts: [(Double, Double)] = [
        (0.0, t / 2.0), (dx, 0.0), (dx, y1), (l - dx, y1), (l - dx, 0.0), (l, t / 2.0),
        (l - dx, t), (l - dx, y2), (dx, y2), (dx, t),
    ]
    let oriented = orient(vertical ? .down : .right, w, h, pts)
    let r = vertical ? DRect(x0: y1, y0: dx, x1: y2, y1: h - dx) : DRect(x0: dx, y0: y1, x1: w - dx, y1: y2)
    return Geometry(paths: [fill(Pb().poly(oriented).takePath())], textRect: r)
}

/// Points given in 21600ths of the box (as ECMA-376 defines many fixed shapes), scaled to it.
func specPts(_ pts: [(Int32, Int32)], _ w: Double, _ h: Double) -> [(Double, Double)] {
    pts.map { (w * Double($0.0) / 21600.0, h * Double($0.1) / 21600.0) }
}

// MARK: - callout wedges

func wedgeRect(_ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ rIn: Double) -> Geometry {
    let tip = DPoint(x: w / 2.0 + w * a0 / 1e5, y: h / 2.0 + h * a1 / 1e5)
    let inside = tip.x > 0.0 && tip.x < w && tip.y > 0.0 && tip.y < h
    let (dx, dy) = ((tip.x - w / 2.0) / w.maximum(1e-9), (tip.y - h / 2.0) / h.maximum(1e-9))
    let b = Pb()
    let r = min(min(rIn, w / 2.0), h / 2.0)
    // Walk clockwise from the top-left; insert the wedge on the edge facing the tip.
    let horiz = abs(dx) > abs(dy)
    var bx0 = w * 5.0 / 12.0
    var bx1 = w * 7.0 / 12.0
    var by0 = h * 5.0 / 12.0
    var by1 = h * 7.0 / 12.0
    if tip.x < w / 2.0 {
        (bx0, bx1) = (w * 2.0 / 12.0, w * 5.0 / 12.0)
    } else {
        (bx0, bx1) = (bx0 + w / 12.0 * 2.0 - w / 12.0 * 2.0, bx1 + w * 2.0 / 12.0)
    }
    if tip.y < h / 2.0 {
        (by0, by1) = (h * 2.0 / 12.0, h * 5.0 / 12.0)
    } else {
        (by0, by1) = (by0, by1 + h * 2.0 / 12.0)
    }
    b.m(r, 0.0)
    if !inside && !horiz && dy < 0.0 {
        b.l(bx0, 0.0).l(tip.x, tip.y).l(bx1, 0.0)
    }
    b.l(w - r, 0.0)
    if r > 0.0 {
        b.arc(r, r, 270.0, 90.0)
    }
    if !inside && horiz && dx > 0.0 {
        b.l(w, by0).l(tip.x, tip.y).l(w, by1)
    }
    b.l(w, h - r)
    if r > 0.0 {
        b.arc(r, r, 0.0, 90.0)
    }
    if !inside && !horiz && dy > 0.0 {
        b.l(bx1, h).l(tip.x, tip.y).l(bx0, h)
    }
    b.l(r, h)
    if r > 0.0 {
        b.arc(r, r, 90.0, 90.0)
    }
    if !inside && horiz && dx < 0.0 {
        b.l(0.0, by1).l(tip.x, tip.y).l(0.0, by0)
    }
    b.l(0.0, r)
    if r > 0.0 {
        b.arc(r, r, 180.0, 90.0)
    }
    b.z()
    return simple(b.takePath(), DRect.new(0.0, 0.0, w, h).inset(-r * 0.29289))
}

// MARK: - cloud

/// ECMA-376 cloud outline arcs (radii in 43200ths of the box, angles in 60000ths of a degree,
/// as DrawingML `arcTo` takes them), from the start point (3900, 14370).
let CLOUD_ARCS: [(Double, Double, Double, Double)] = [
    (6753.0, 9190.0, -11429249.0, 7426832.0),
    (5333.0, 7267.0, -8646143.0, 5396714.0),
    (4365.0, 5945.0, -8748475.0, 5983381.0),
    (4857.0, 6595.0, -7859164.0, 7034504.0),
    (5333.0, 7273.0, -4722533.0, 6541615.0),
    (6775.0, 9220.0, -2776035.0, 7816140.0),
    (5785.0, 7867.0, 37501.0, 6842000.0),
    (6752.0, 9215.0, 1347096.0, 6910353.0),
    (7720.0, 10543.0, 3974558.0, 4542661.0),
    (4360.0, 5918.0, -16496525.0, 8804134.0),
    (4345.0, 5945.0, -14809710.0, 9151131.0),
]

/// The cloud's creases: short arcs inside the outline, each from its own start point.
let CLOUD_CREASES: [(Double, Double, Double, Double, Double, Double)] = [
    (4693.0, 26177.0, 4345.0, 5945.0, 5204520.0, 1585770.0),
    (6928.0, 34899.0, 4360.0, 5918.0, 4416628.0, 686848.0),
    (16478.0, 39090.0, 6752.0, 9215.0, 8257449.0, 844866.0),
    (28827.0, 34751.0, 6752.0, 9215.0, 387196.0, 959901.0),
    (34129.0, 22954.0, 5785.0, 7867.0, -4217541.0, 4255042.0),
    (41798.0, 15354.0, 5333.0, 7273.0, 1819082.0, 1665090.0),
    (38324.0, 5426.0, 4857.0, 6595.0, -824660.0, 891534.0),
    (29078.0, 3952.0, 4857.0, 6595.0, -8950887.0, 1091722.0),
    (22141.0, 4720.0, 4365.0, 5945.0, -9809656.0, 1061181.0),
    (14000.0, 5192.0, 6753.0, 9190.0, -4002417.0, 739161.0),
    (4127.0, 15789.0, 6753.0, 9190.0, 9459261.0, 711490.0),
]

func cloud(_ name: String, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
    // Drawn in the path's own 43200-unit square, then stretched to the box (as DrawingML lays out
    // a path with its own w and h), so the arcs keep their shape's proportions at any aspect.
    let toBox = DAffine.scaleNonUniform(w / 43200.0, h / 43200.0)
    func deg(_ v: Double) -> Double { v / 60000.0 }
    let b = Pb()
    b.m(3900.0, 14370.0)
    for (wr, hr, st, sw) in CLOUD_ARCS {
        b.arcSpec(wr, hr, deg(st), deg(sw))
    }
    b.z()
    let creases = Pb()
    for (x, y, wr, hr, st, sw) in CLOUD_CREASES {
        creases.m(x, y).arcSpec(wr, hr, deg(st), deg(sw))
    }
    var outline = b.takePath()
    outline.applyAffine(toBox)
    var paths = [fill(outline)]
    if name == "cloud" {
        var c = creases.takePath()
        c.applyAffine(toBox)
        paths.append(strokeOnly(c))
    }
    let textRect = DRect(x0: w * 2977.0 / 21600.0, y0: h * 3262.0 / 21600.0, x1: w * 17087.0 / 21600.0, y1: h * 17337.0 / 21600.0)
    if name == "cloudCallout" {
        let tip = DPoint(x: w / 2.0 + w * a0 / 1e5, y: h / 2.0 + h * a1 / 1e5)
        let c = DPoint(x: w / 2.0, y: h / 2.0)
        let bubbles = Pb()
        for (k, r) in [(0.55, 0.06), (0.75, 0.045), (0.95, 0.03)] {
            let p = c + (tip - c) * k
            if !(p.x > w * 0.1 && p.x < w * 0.9 && p.y > h * 0.1 && p.y < h * 0.9) || k > 0.9 {
                bubbles.ellipse(p.x, p.y, w * r, h * r)
            }
        }
        paths.append(fill(bubbles.takePath()))
    }
    return Geometry(paths: paths, textRect: textRect)
}

// MARK: - equation shapes

/// The equation shapes, by ECMA-376's formulas (checked against PowerPoint's outlines at several
/// sizes and adjust values). Their bars span 73.49% of the width; the plus and multiply bars are
/// `adj1` of the shorter side thick, the others' `adj1` of the height.
func math(_ name: String, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
    func pin(_ lo: Double, _ v: Double, _ hi: Double) -> Double {
        min(v.maximum(lo), hi.maximum(lo))
    }
    let ss = min(w, h)
    let (hc, vc) = (w / 2.0, h / 2.0)
    let dx1 = w * 73490.0 / 200000.0
    let (x1, x2) = (hc - dx1, hc + dx1)
    let b = Pb()
    let text: DRect
    switch name {
    case "mathPlus":
        let a = pin(0.0, a0, 73490.0)
        let dy1 = h * 73490.0 / 200000.0
        let dx2 = ss * a / 200000.0
        let (y1, y2, y3, y4) = (vc - dy1, vc - dx2, vc + dx2, vc + dy1)
        let (xa, xb) = (hc - dx2, hc + dx2)
        b.poly([(x1, y2), (xa, y2), (xa, y1), (xb, y1), (xb, y2), (x2, y2), (x2, y3), (xb, y3), (xb, y4), (xa, y4), (xa, y3), (x1, y3)])
        text = DRect(x0: x1, y0: y2, x1: x2, y1: y3)
    case "mathMinus":
        let dy1 = h * pin(0.0, a0, 100000.0) / 200000.0
        b.poly([(x1, vc - dy1), (x2, vc - dy1), (x2, vc + dy1), (x1, vc + dy1)])
        text = DRect(x0: x1, y0: vc - dy1, x1: x2, y1: vc + dy1)
    case "mathEqual":
        let a = pin(0.0, a0, 36745.0)
        let g = pin(0.0, a1, 100000.0 - 2.0 * a)
        let (dy1, dy2) = (h * a / 100000.0, h * g / 200000.0)
        let (y2, y3) = (vc - dy2, vc + dy2)
        let (y1, y4) = (y2 - dy1, y3 + dy1)
        b.poly([(x1, y1), (x2, y1), (x2, y2), (x1, y2)])
        b.poly([(x1, y3), (x2, y3), (x2, y4), (x1, y4)])
        text = DRect(x0: x1, y0: y1, x1: x2, y1: y4)
    case "mathNotEqual":
        let a = pin(0.0, a0, 50000.0)
        let crAng = pin(4200000.0, a1, 6600000.0)
        let g = pin(0.0, a2, 100000.0 - 2.0 * a)
        let (dy1, dy2) = (h * a / 100000.0, h * g / 200000.0)
        let hd2 = max(h / 2.0, 1e-9)
        let (y2, y3) = (vc - dy2, vc + dy2)
        let (y1, y4) = (y2 - dy1, y3 + dy1)
        let cadj2 = crAng - 5400000.0
        let xadj2 = hd2 * tan((cadj2 / 60000.0).toRadians)
        let len = (xadj2 * xadj2 + hd2 * hd2).squareRoot()
        let bhw = len * dy1 / hd2
        let x7 = hc + xadj2 - bhw / 2.0
        func at(_ y: Double) -> Double { x7 - xadj2 * y / hd2 }
        let (x6, x5, x4, x3) = (at(y1), at(y2), at(y3), at(y4))
        let rx7 = x7 + bhw
        let dx7 = dy1 * hd2 / len
        let dy3 = dy1 * xadj2 / len
        let (rx, lx, ry, ly) = cadj2 > 0.0 ? (x7 + dx7, x7, dy3, 0.0) : (rx7, rx7 - dx7, 0.0, -dy3)
        b.poly([
            (x1, y1), (x6, y1), (lx, ly), (rx, ry), (x6 + bhw, y1), (x2, y1),
            (x2, y2), (x5 + bhw, y2), (x4 + bhw, y3), (x2, y3), (x2, y4), (x3 + bhw, y4),
            (w - lx, h - ly), (w - rx, h - ry), (x3, y4), (x1, y4), (x1, y3), (x4, y3),
            (x5, y2), (x1, y2),
        ])
        text = DRect(x0: x1, y0: y1, x1: x2, y1: y4)
    case "mathDivide":
        let a = pin(1000.0, a0, 36745.0)
        let max3 = min((73490.0 - a) / 4.0, 36745.0 * w / h.maximum(1e-9))
        let r3 = pin(1000.0, a2, max3)
        let g = pin(0.0, a1, 73490.0 - 4.0 * r3 - a)
        let dy1 = h * a / 200000.0
        let yg = h * g / 100000.0
        let rad = h * r3 / 100000.0
        let (y3, y4) = (vc - dy1, vc + dy1)
        let y2 = y3 - (yg + rad)
        let y1 = y2 - rad
        b.ellipse(hc, y1 + rad, rad, rad)
        b.ellipse(hc, h - y1 - rad, rad, rad)
        b.poly([(x1, y3), (x2, y3), (x2, y4), (x1, y4)])
        text = DRect(x0: x1, y0: y3, x1: x2, y1: y4)
    default:
        // mathMultiply: an X whose arms run along the box's diagonals.
        let th = ss * pin(0.0, a0, 51965.0) / 100000.0
        let ang = atan2(h, w)
        let (sa, ca, ta) = (sin(ang), cos(ang), max(tan(ang), 1e-9))
        let lm = (w * w + h * h).squareRoot() * (1.0 - 51965.0 / 100000.0)
        let (xm, ym) = (ca * lm / 2.0, sa * lm / 2.0)
        let (dxam, dyam) = (sa * th / 2.0, ca * th / 2.0)
        let (xa, ya, xb, yb) = (xm - dxam, ym + dyam, xm + dxam, ym - dyam)
        let yc = (hc - xb) * ta + yb
        let (xd, xe) = (w - xb, w - xa)
        let xfe = (vc - ya) / ta
        let (xf, xl) = (xe - xfe, xa + xfe)
        let (yg, yh, yi) = (h - ya, h - yb, h - yc)
        b.poly([(xa, ya), (xb, yb), (hc, yc), (xd, yb), (xe, ya), (xf, vc), (xe, yg), (xd, yh), (hc, yi), (xb, yh), (xa, yg), (xl, vc)])
        text = DRect(x0: xa, y0: yb, x1: xe, y1: yh)
    }
    return Geometry(paths: [fill(b.takePath())], textRect: text)
}

// MARK: - ribbons, scrolls, action buttons

func ribbon(up: Bool, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
    let fold = h * clamp(a0, 0.0, 33333.0) / 1e5
    let cw = w * clamp(a1, 25000.0, 75000.0) / 1e5 // centre band width
    let x0 = (w - cw) / 2.0
    let x1 = w - x0
    let ear = w / 8.0
    let (top, bot) = (0.0, h)
    let b = Pb()
    let shadeP = Pb()
    if up {
        // centre band sits high; ends hang low.
        b.poly([(x0, top), (x1, top), (x1, bot - fold), (x0, bot - fold)])
        let ends = Pb()
        ends.poly([(0.0, fold), (x0 + ear * 0.5, fold), (x0 + ear * 0.5, bot), (0.0, bot), (ear, (fold + bot) / 2.0)])
        ends.poly([(w, fold), (x1 - ear * 0.5, fold), (x1 - ear * 0.5, bot), (w, bot), (w - ear, (fold + bot) / 2.0)])
        shadeP.poly([(x0, bot - fold), (x0 + ear * 0.5, bot - fold), (x0 + ear * 0.5, bot)])
        shadeP.poly([(x1, bot - fold), (x1 - ear * 0.5, bot - fold), (x1 - ear * 0.5, bot)])
        let text = DRect(x0: x0, y0: top, x1: x1, y1: bot - fold)
        return Geometry(
            paths: [fill(ends.takePath()), shade(shadeP.takePath(), .darkenLess), fill(b.takePath())],
            textRect: text
        )
    }
    b.poly([(x0, top + fold), (x1, top + fold), (x1, bot), (x0, bot)])
    let ends = Pb()
    ends.poly([(0.0, top), (x0 + ear * 0.5, top), (x0 + ear * 0.5, bot - fold), (0.0, bot - fold), (ear, (bot - fold) / 2.0)])
    ends.poly([(w, top), (x1 - ear * 0.5, top), (x1 - ear * 0.5, bot - fold), (w, bot - fold), (w - ear, (bot - fold) / 2.0)])
    shadeP.poly([(x0, top + fold), (x0 + ear * 0.5, top + fold), (x0 + ear * 0.5, top)])
    shadeP.poly([(x1, top + fold), (x1 - ear * 0.5, top + fold), (x1 - ear * 0.5, top)])
    let text = DRect(x0: x0, y0: top + fold, x1: x1, y1: bot)
    return Geometry(
        paths: [fill(ends.takePath()), shade(shadeP.takePath(), .darkenLess), fill(b.takePath())],
        textRect: text
    )
}

func scroll(vertical: Bool, _ w: Double, _ h: Double, _ a0: Double) -> Geometry {
    let ss = min(w, h)
    let r = ss * clamp(a0, 0.0, 25000.0) / 1e5 / 2.0
    let b = Pb()
    let curl = Pb()
    if vertical {
        b.poly([(r, r * 2.0), (w - r, r * 2.0), (w - r, h - r), (r, h - r)])
        b.ellipse(w / 2.0, r, w / 2.0 - r * 0.0, r)
        curl.ellipse(r, h - r, r, r)
        curl.ellipse(w - r * 2.0, r, r * 0.5, r * 0.5)
        let text = DRect(x0: r, y0: r * 2.0, x1: w - r, y1: h - r)
        return Geometry(paths: [fill(b.takePath()), shade(curl.takePath(), .darkenLess)], textRect: text)
    }
    b.poly([(r * 2.0, r), (w - r, r), (w - r, h - r), (r * 2.0, h - r)])
    b.ellipse(r, h / 2.0, r, h / 2.0)
    curl.ellipse(w - r, r, r, r)
    curl.ellipse(r, h - r * 2.0, r * 0.5, r * 0.5)
    let text = DRect(x0: r * 2.0, y0: r, x1: w - r, y1: h - r)
    return Geometry(paths: [fill(b.takePath()), shade(curl.takePath(), .darkenLess)], textRect: text)
}

func actionButton(_ name: String, _ w: Double, _ h: Double) -> Geometry {
    let body = cornerRect(w, h, [.square, .square, .square, .square])
    let ss = min(w, h)
    let (cx, cy) = (w / 2.0, h / 2.0)
    let s = ss * 0.3
    let g = Pb()
    switch name {
    case "actionButtonBackPrevious":
        g.poly([(cx + s, cy - s), (cx + s, cy + s), (cx - s, cy)])
    case "actionButtonForwardNext":
        g.poly([(cx - s, cy - s), (cx - s, cy + s), (cx + s, cy)])
    case "actionButtonBeginning":
        g.poly([(cx + s, cy - s), (cx + s, cy + s), (cx - s * 0.6, cy)])
        g.poly([(cx - s, cy - s), (cx - s * 0.7, cy - s), (cx - s * 0.7, cy + s), (cx - s, cy + s)])
    case "actionButtonEnd":
        g.poly([(cx - s, cy - s), (cx - s, cy + s), (cx + s * 0.6, cy)])
        g.poly([(cx + s * 0.7, cy - s), (cx + s, cy - s), (cx + s, cy + s), (cx + s * 0.7, cy + s)])
    case "actionButtonHome":
        g.poly([
            (cx, cy - s), (cx + s, cy), (cx + s * 0.7, cy), (cx + s * 0.7, cy + s),
            (cx - s * 0.7, cy + s), (cx - s * 0.7, cy), (cx - s, cy),
        ])
    case "actionButtonInformation", "actionButtonHelp":
        g.ellipse(cx, cy, s, s)
    case "actionButtonReturn":
        g.m(cx + s, cy - s * 0.6).l(cx + s, cy + s * 0.2).q(cx + s, cy + s * 0.8, cx + s * 0.4, cy + s * 0.8).l(cx - s * 0.5, cy + s * 0.8)
        g.l(cx - s * 0.5, cy + s * 0.4)
            .l(cx - s, cy + s * 0.9)
            .l(cx - s * 0.5, cy + s * 1.4)
            .l(cx - s * 0.5, cy + s)
            .l(cx + s * 0.6, cy + s)
            .l(cx + s * 0.6, cy - s * 0.6)
            .z()
    case "actionButtonMovie":
        g.poly([(cx - s, cy - s * 0.6), (cx + s * 0.4, cy - s * 0.6), (cx + s * 0.4, cy + s * 0.6), (cx - s, cy + s * 0.6)])
        g.poly([(cx + s * 0.4, cy), (cx + s, cy - s * 0.5), (cx + s, cy + s * 0.5)])
    case "actionButtonDocument":
        g.poly([(cx - s * 0.7, cy - s), (cx + s * 0.3, cy - s), (cx + s * 0.7, cy - s * 0.6), (cx + s * 0.7, cy + s), (cx - s * 0.7, cy + s)])
    case "actionButtonSound":
        g.poly([
            (cx - s, cy - s * 0.35), (cx - s * 0.5, cy - s * 0.35), (cx, cy - s),
            (cx, cy + s), (cx - s * 0.5, cy + s * 0.35), (cx - s, cy + s * 0.35),
        ])
    default:
        break
    }
    return Geometry(paths: [fill(body), shade(g.takePath(), .darkenLess)], textRect: DRect.new(0.0, 0.0, w, h))
}

// MARK: - build

/// Builds the geometry for preset `name` at size `w`×`h` with adjust values `adj` (missing
/// values use the preset's defaults). Unknown names return `nil`; the caller falls back to `rect`.
public func presetBuild(_ name: String, _ w: Double, _ h: Double, _ adj: [Double]) -> Geometry? {
    if !(w.isFinite && h.isFinite) {
        return nil
    }
    let w = max(w, 0.0)
    let h = max(h, 0.0)
    let defaults = presetInfo(name)?.defaults ?? []
    let a = { (i: Int) -> Double in
        let v: Double
        if i < adj.count {
            v = adj[i]
        } else if i < defaults.count {
            v = defaults[i]
        } else {
            v = 0.0
        }
        return v.isFinite ? v : 0.0
    }
    let ss = min(w, h)
    let full = DRect.new(0.0, 0.0, w, h)
    let b = Pb()
    let g: Geometry
    switch name {
    case "rect", "textBox", "flowChartProcess":
        g = simple(cornerRect(w, h, [.square, .square, .square, .square]), full)
    case "actionButtonBlank", "actionButtonBackPrevious", "actionButtonForwardNext", "actionButtonBeginning",
         "actionButtonEnd", "actionButtonHome", "actionButtonInformation", "actionButtonReturn",
         "actionButtonMovie", "actionButtonDocument", "actionButtonSound", "actionButtonHelp":
        g = actionButton(name, w, h)
    case "roundRect":
        let v = clamp(a(0), 0.0, 50000.0)
        let r = ss * v / 100000.0
        g = simple(cornerRect(w, h, [.round(r), .round(r), .round(r), .round(r)]), full.inset(-r * 0.29289))
    case "flowChartAlternateProcess":
        g = simple(cornerRect(w, h, [.round(ss / 6.0), .round(ss / 6.0), .round(ss / 6.0), .round(ss / 6.0)]), full.inset(-ss / 6.0 * 0.29289))
    case "snip1Rect":
        let v = clamp(a(0), 0.0, 50000.0)
        let d = ss * v / 100000.0
        g = simple(
            cornerRect(w, h, [.square, .snip(d), .square, .square]),
            DRect.new(0.0, d / 2.0, w - d / 2.0, h)
        )
    case "snip2SameRect":
        let (d1, d2) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5)
        g = simple(cornerRect(w, h, [.snip(d1), .snip(d1), .snip(d2), .snip(d2)]), full.inset(-max(d1, d2) / 2.0))
    case "snip2DiagRect":
        let (d1, d2) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5)
        g = simple(cornerRect(w, h, [.snip(d1), .snip(d2), .snip(d1), .snip(d2)]), full.inset(-max(d1, d2) / 2.0))
    case "snipRoundRect":
        let (r, d) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5)
        g = simple(cornerRect(w, h, [.round(r), .snip(d), .square, .square]), full.inset(-max(r, d) / 2.0))
    case "round1Rect":
        let r = ss * clamp(a(0), 0.0, 50000.0) / 1e5
        g = simple(cornerRect(w, h, [.square, .round(r), .square, .square]), full.inset(-r * 0.29289))
    case "round2SameRect":
        let (r1, r2) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5)
        g = simple(cornerRect(w, h, [.round(r1), .round(r1), .round(r2), .round(r2)]), full.inset(-max(r1, r2) * 0.29289))
    case "round2DiagRect":
        let (r1, r2) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5)
        g = simple(cornerRect(w, h, [.round(r1), .round(r2), .round(r1), .round(r2)]), full.inset(-max(r1, r2) * 0.29289))
    case "ellipse", "flowChartConnector":
        g = simple(b.ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0).takePath(), DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355))
    case "triangle", "flowChartExtract":
        let v = name == "triangle" ? clamp(a(0), 0.0, 100000.0) : 50000.0
        let ax = w * v / 100000.0
        g = simple(b.poly([(0.0, h), (ax, 0.0), (w, h)]).takePath(), DRect.new(ax / 2.0, h / 2.0, (ax + w) / 2.0, h))
    case "flowChartMerge":
        g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w / 2.0, h)]).takePath(), DRect.new(w / 4.0, 0.0, w * 0.75, h / 2.0))
    case "rtTriangle":
        g = simple(b.poly([(0.0, 0.0), (0.0, h), (w, h)]).takePath(), DRect.new(w / 12.0, h * 7.0 / 12.0, w * 7.0 / 12.0, h * 11.0 / 12.0))
    case "parallelogram", "flowChartInputOutput":
        let v = name == "parallelogram" ? clamp(a(0), 0.0, 100000.0 * w / ss.maximum(1e-9)) : 20000.0 * w / ss.maximum(1e-9)
        let off = ss * v / 100000.0
        g = simple(
            b.poly([(0.0, h), (off, 0.0), (w, 0.0), (w - off, h)]).takePath(),
            DRect.new(off / 2.0 + off * 0.2, h * 0.08, w - off / 2.0 - off * 0.2, h * 0.92)
        )
    case "trapezoid":
        let v = clamp(a(0), 0.0, 50000.0 * w / ss.maximum(1e-9))
        let off = ss * v / 100000.0
        g = simple(b.poly([(0.0, h), (off, 0.0), (w - off, 0.0), (w, h)]).takePath(), DRect.new(off * 0.66, h * 0.2, w - off * 0.66, h))
    case "flowChartManualOperation":
        g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w * 0.8, h), (w * 0.2, h)]).takePath(), DRect.new(w * 0.2, 0.0, w * 0.8, h))
    case "diamond", "flowChartDecision":
        g = simple(
            b.poly([(w / 2.0, 0.0), (w, h / 2.0), (w / 2.0, h), (0.0, h / 2.0)]).takePath(),
            DRect.new(w / 4.0, h / 4.0, w * 0.75, h * 0.75)
        )
    case "flowChartSort":
        let d = b.poly([(w / 2.0, 0.0), (w, h / 2.0), (w / 2.0, h), (0.0, h / 2.0)]).takePath()
        let line = Pb().m(0.0, h / 2.0).l(w, h / 2.0).takePath()
        g = Geometry(paths: [fill(d), strokeOnly(line)], textRect: DRect.new(w / 4.0, h / 4.0, w * 0.75, h * 0.75))
    case "pentagon":
        g = simple(b.poly(polygonRegular(5, w, h, -90.0)).takePath(), DRect.new(w * 0.2, h * 0.27, w * 0.8, h * 0.9))
    case "heptagon":
        g = simple(b.poly(polygonRegular(7, w, h, -90.0)).takePath(), DRect.new(w * 0.16, h * 0.2, w * 0.84, h * 0.86))
    case "decagon":
        g = simple(b.poly(polygonRegular(10, w, h, 0.0)).takePath(), DRect.new(w * 0.1, h * 0.17, w * 0.9, h * 0.83))
    case "dodecagon":
        g = simple(b.poly(polygonRegular(12, w, h, 15.0)).takePath(), DRect.new(w * 0.13, h * 0.13, w * 0.87, h * 0.87))
    case "hexagon", "flowChartPreparation":
        let v = name == "hexagon" ? clamp(a(0), 0.0, 50000.0 * w / ss.maximum(1e-9)) : 20000.0 * w / ss.maximum(1e-9)
        let off = ss * v / 100000.0
        g = simple(
            b.poly([(0.0, h / 2.0), (off, 0.0), (w - off, 0.0), (w, h / 2.0), (w - off, h), (off, h)]).takePath(),
            DRect.new(off * 0.6, h * 0.14, w - off * 0.6, h * 0.86)
        )
    case "octagon":
        let v = clamp(a(0), 0.0, 50000.0)
        let d = ss * v / 100000.0
        g = simple(
            b.poly([(d, 0.0), (w - d, 0.0), (w, d), (w, h - d), (w - d, h), (d, h), (0.0, h - d), (0.0, d)]).takePath(),
            full.inset(-d / 2.0)
        )
    case "plus":
        let v = clamp(a(0), 0.0, 50000.0)
        let d = ss * v / 100000.0
        g = simple(
            b.poly([
                (d, 0.0), (w - d, 0.0), (w - d, d), (w, d), (w, h - d), (w - d, h - d), (w - d, h),
                (d, h), (d, h - d), (0.0, h - d), (0.0, d), (d, d),
            ]).takePath(),
            DRect.new(0.0, d, w, h - d)
        )
    case "frame":
        let v = clamp(a(0), 0.0, 50000.0)
        let t = ss * v / 100000.0
        b.poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)])
        b.poly([(t, t), (w - t, t), (w - t, h - t), (t, h - t)])
        g = Geometry(paths: [fillEO(b.takePath())], textRect: full.inset(-t))
    case "halfFrame":
        let (t1, t2) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5)
        g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w - t1, t1), (t2, t1), (t2, h - t2), (0.0, h)]).takePath(), full)
    case "corner":
        let (t1, t2) = (ss * clamp(a(0), 0.0, 100000.0) / 1e5, ss * clamp(a(1), 0.0, 100000.0) / 1e5)
        g = simple(b.poly([(0.0, 0.0), (t2, 0.0), (t2, h - t1), (w, h - t1), (w, h), (0.0, h)]).takePath(), DRect.new(0.0, h - t1, w, h))
    case "diagStripe":
        let k = clamp(a(0), 0.0, 100000.0) / 1e5
        g = simple(b.poly([(0.0, h * k), (w * k, 0.0), (w, 0.0), (0.0, h)]).takePath(), DRect.new(0.0, 0.0, w / 2.0, h / 2.0))
    case "plaque":
        let v = clamp(a(0), 0.0, 50000.0)
        let r = ss * v / 100000.0
        b.m(0.0, r)
            .arc(r, r, 90.0, -90.0)
            .l(w - r, 0.0)
            .arc(r, r, 180.0, -90.0)
            .l(w, h - r)
            .arc(r, r, 270.0, -90.0)
            .l(r, h)
            .arc(r, r, 0.0, -90.0)
            .z()
        g = simple(b.takePath(), full.inset(-r * 0.7))
    case "can", "flowChartMagneticDisk":
        // The disk's ends are a third of its height (ECMA-376: ellipses of radius h/6).
        let v = name == "can" ? clamp(a(0), 0.0, 50000.0 * h / ss.maximum(1e-9)) : 100000.0 / 3.0 * h / ss.maximum(1e-9)
        let eh = ss * v / 100000.0
        let r = eh / 2.0
        let body = Pb().m(0.0, r).l(0.0, h - r).arc(w / 2.0, r, 180.0, -180.0).l(w, r).arc(w / 2.0, r, 0.0, -180.0).z().takePath()
        let top = Pb().ellipse(w / 2.0, r, w / 2.0, r).takePath()
        g = Geometry(
            paths: [fill(body), shade(top, name == "can" ? .lighten : .norm)],
            textRect: DRect.new(0.0, eh, w, h - r)
        )
    case "flowChartMagneticDrum":
        // ECMA-376: end ellipses of radius w/6 across.
        let r = w / 6.0
        let body = Pb().m(r, 0.0).l(w - r, 0.0).arc(r, h / 2.0, 270.0, 180.0).l(r, h).arc(r, h / 2.0, 90.0, 180.0).z().takePath()
        let side = Pb().m(w - r, 0.0).arc(r, h / 2.0, 270.0, -180.0).takePath()
        g = Geometry(paths: [fill(body), strokeOnly(side)], textRect: DRect.new(r, 0.0, w - 2.0 * r, h))
    case "cube":
        let v = clamp(a(0), 0.0, 100000.0)
        let d = ss * v / 100000.0
        let front = Pb().poly([(0.0, d), (w - d, d), (w - d, h), (0.0, h)]).takePath()
        let top = Pb().poly([(0.0, d), (d, 0.0), (w, 0.0), (w - d, d)]).takePath()
        let side = Pb().poly([(w - d, d), (w, 0.0), (w, h - d), (w - d, h)]).takePath()
        g = Geometry(
            paths: [fill(front), shade(top, .lightenLess), shade(side, .darkenLess)],
            textRect: DRect.new(0.0, d, w - d, h)
        )
    case "bevel":
        let v = clamp(a(0), 0.0, 50000.0)
        let d = ss * v / 100000.0
        let inner = Pb().poly([(d, d), (w - d, d), (w - d, h - d), (d, h - d)]).takePath()
        let top = Pb().poly([(0.0, 0.0), (w, 0.0), (w - d, d), (d, d)]).takePath()
        let left = Pb().poly([(0.0, 0.0), (d, d), (d, h - d), (0.0, h)]).takePath()
        let right = Pb().poly([(w, 0.0), (w, h), (w - d, h - d), (w - d, d)]).takePath()
        let bottom = Pb().poly([(0.0, h), (d, h - d), (w - d, h - d), (w, h)]).takePath()
        g = Geometry(
            paths: [
                fill(inner), shade(top, .lightenLess), shade(left, .lighten),
                shade(right, .darkenLess), shade(bottom, .darken),
            ],
            textRect: full.inset(-d)
        )
    case "donut":
        let v = clamp(a(0), 0.0, 50000.0)
        let t = ss * v / 100000.0
        b.ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0)
        b.ellipse(w / 2.0, h / 2.0, max(w / 2.0 - t, 0.0), max(h / 2.0 - t, 0.0))
        g = Geometry(paths: [fillEO(b.takePath())], textRect: DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355))
    case "noSmoking":
        let v = clamp(a(0), 0.0, 50000.0)
        let t = ss * v / 100000.0
        let (rx, ry) = (max(w / 2.0 - t, 0.0), max(h / 2.0 - t, 0.0))
        b.ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0)
        b.ellipse(w / 2.0, h / 2.0, rx, ry)
        let ring = b.takePath()
        let th = atan2(h, w)
        let dir = DVec(dx: cos(th), dy: sin(th))
        let r = rx > 0.0 && ry > 0.0
            ? rx * ry / ((ry * cos(th) * ry * cos(th) + rx * sin(th) * rx * sin(th)).squareRoot())
            : 0.0
        let perp = DVec(dx: -dir.dy, dy: dir.dx) * (t / 2.0)
        let c = DPoint(x: w / 2.0, y: h / 2.0)
        let p = [c - dir * r - perp, c + dir * r - perp, c + dir * r + perp, c - dir * r + perp]
        let bar = Pb().poly(p.map { ($0.x, $0.y) }).takePath()
        g = Geometry(
            paths: [fillEO(ring), fill(bar)],
            textRect: DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355)
        )
    case "blockArc":
        let st = a(0) / 60000.0
        let en = a(1) / 60000.0
        let t = ss * clamp(a(2), 0.0, 50000.0) / 100000.0
        var sw = en - st
        if sw <= 0.0 {
            sw += 360.0
        }
        let (rx, ry) = (w / 2.0, h / 2.0)
        let (irx, iry) = (max(rx - t, 0.0), max(ry - t, 0.0))
        let s0 = vis(st, rx, ry)
        let e0 = vis(st + sw, rx, ry)
        var sweep = e0 - s0
        if sweep <= 0.0 {
            sweep += 360.0
        }
        let si = vis(st + sw, irx, iry)
        let ei = vis(st, irx, iry)
        var isweep = ei - si
        if isweep >= 0.0 {
            isweep -= 360.0
        }
        let p0 = DPoint(x: w / 2.0 + rx * cos(s0.toRadians), y: h / 2.0 + ry * sin(s0.toRadians))
        b.m(p0.x, p0.y).arc(rx, ry, s0, sweep)
        let pi = DPoint(x: w / 2.0 + irx * cos(si.toRadians), y: h / 2.0 + iry * sin(si.toRadians))
        b.l(pi.x, pi.y).arc(irx, iry, si, isweep).z()
        g = simple(b.takePath(), full)
    case "pie", "chord", "arc":
        let (rx, ry) = (w / 2.0, h / 2.0)
        let s = vis(a(0) / 60000.0, rx, ry)
        let e = vis(a(1) / 60000.0, rx, ry)
        var sw = e - s
        if sw <= 0.0 {
            sw += 360.0
        }
        let p0 = DPoint(x: rx + rx * cos(s.toRadians), y: ry + ry * sin(s.toRadians))
        b.m(p0.x, p0.y).arc(rx, ry, s, sw)
        let text = DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355)
        if name == "pie" {
            b.l(rx, ry).z()
            g = simple(b.takePath(), text)
        } else if name == "chord" {
            b.z()
            g = simple(b.takePath(), text)
        } else {
            let open = b.takePath()
            var f = GeomPath(elements: open.elements)
            f.line(DPoint(x: rx, y: ry))
            f.close()
            g = Geometry(paths: [fillOnly(f), strokeOnly(open)], textRect: text)
        }
    case "teardrop":
        let k = clamp(a(0), 0.0, 200000.0) / 100000.0
        let tip = (w / 2.0 + w / 2.0 * k, h / 2.0 - h / 2.0 * k)
        b.m(0.0, h / 2.0).arc(w / 2.0, h / 2.0, 180.0, 90.0)
        b.q(w / 2.0 + w / 4.0 * k, 0.0, tip.0, tip.1).q(w, h / 2.0 - h / 4.0 * k, w, h / 2.0)
        b.arc(w / 2.0, h / 2.0, 0.0, 180.0).z()
        g = simple(b.takePath(), DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355))
    case "foldedCorner":
        let v = clamp(a(0), 0.0, 50000.0)
        let d = ss * v / 100000.0
        let body = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h - d), (w - d, h), (0.0, h)]).takePath()
        let fold = Pb().m(w - d, h).l(w - d + d * 0.2, h - d + d * 0.2).l(w, h - d).z().takePath()
        g = Geometry(
            paths: [fill(body), shade(fold, .darkenLess)],
            textRect: DRect.new(0.0, 0.0, w, h - d)
        )
    case "smileyFace":
        let k = clamp(a(0), -4653.0, 4653.0) / 100000.0
        let face = Pb().ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0).takePath()
        let eyes = Pb()
        eyes.ellipse(w * 0.35, h * 0.37, w * 0.05, h * 0.05)
        eyes.ellipse(w * 0.65, h * 0.37, w * 0.05, h * 0.05)
        let ys = h * (0.72 - k)
        let smile = Pb().m(w * 0.22, ys).q(w / 2.0, ys + h * k * 4.0 + h * 0.0, w * 0.78, ys).takePath()
        g = Geometry(
            paths: [fill(face), shade(eyes.takePath(), .darkenLess), strokeOnly(smile)],
            textRect: DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355)
        )
    case "heart":
        // ECMA-376 heart: two cubic curves from the notch at the top to the point.
        let (dx1, dx2) = (w * 49.0 / 48.0, w * 10.0 / 48.0)
        let y1 = -h / 3.0
        b.m(w / 2.0, h / 4.0)
            .c(w / 2.0 + dx2, y1, w / 2.0 + dx1, h / 4.0, w / 2.0, h)
            .c(w / 2.0 - dx1, h / 4.0, w / 2.0 - dx2, y1, w / 2.0, h / 4.0)
            .z()
        g = simple(b.takePath(), DRect.new(w * 0.2, h * 0.25, w * 0.8, h * 0.7))
    case "lightningBolt":
        // ECMA-376 lightningBolt, in 21600ths of the box.
        let pts = specPts([
            (8472, 0), (12860, 6080), (11050, 6797), (16577, 12007), (14767, 12877),
            (21600, 21600), (10012, 14915), (12222, 13987), (5022, 9705), (7602, 8382), (0, 3890),
        ], w, h)
        g = simple(b.poly(pts).takePath(), DRect.new(w * 8757.0 / 21600.0, h * 7637.0 / 21600.0, w * 13917.0 / 21600.0, h * 12963.0 / 21600.0))
    case "sun":
        // ECMA-376 sun: eight triangular rays (their bases at fixed fractions of the core's
        // margin) around a circle of radius 50% - adj.
        let aSun = clamp(a(0), 12500.0, 46875.0)
        let g0 = 50000.0 - aSun
        let (g1, g2) = (g0 * 30274.0 / 32768.0, g0 * 12540.0 / 32768.0)
        let (g10, g11) = ((50000.0 - g1) * 0.75, (50000.0 - g2) * 0.75)
        let (g12, g13, g14) = (g10 + 3662.0, g11 + 3662.0, g11 + 12500.0)
        let (g15, g16, g17, g18) = (100000.0 - g10, 100000.0 - g12, 100000.0 - g13, 100000.0 - g14)
        func x(_ gv: Double) -> Double { w * gv / 100000.0 }
        func y(_ gv: Double) -> Double { h * gv / 100000.0 }
        let (ox1, oy1, ox2, oy2) = (w * 18436.0 / 21600.0, h * 3163.0 / 21600.0, w * 3163.0 / 21600.0, h * 18436.0 / 21600.0)
        let (hc, vc) = (w / 2.0, h / 2.0)
        b.poly([(w, vc), (x(g15), y(g18)), (x(g15), y(g14))])
        b.poly([(ox1, oy1), (x(g16), y(g13)), (x(g17), y(g12))])
        b.poly([(hc, 0.0), (x(g18), y(g10)), (x(g14), y(g10))])
        b.poly([(ox2, oy1), (x(g13), y(g12)), (x(g12), y(g13))])
        b.poly([(0.0, vc), (x(g10), y(g14)), (x(g10), y(g18))])
        b.poly([(ox2, oy2), (x(g12), y(g17)), (x(g13), y(g16))])
        b.poly([(hc, h), (x(g14), y(g15)), (x(g18), y(g15))])
        b.poly([(ox1, oy2), (x(g17), y(g16)), (x(g16), y(g17))])
        b.ellipse(hc, vc, x(g0), y(g0))
        let g7 = g0 * 23170.0 / 32768.0
        g = simple(b.takePath(), DRect.new(x(50000.0 - g7), y(50000.0 - g7), x(50000.0 + g7), y(50000.0 + g7)))
    case "moon":
        // ECMA-376 moon: the outer edge is the left half of an ellipse w × h/2 centred on the
        // right edge; the inner edge an arc through the corners and (adj · w, middle) of a
        // larger ellipse (rx = g18, ry = dy1) whose centre lies right of that point.
        let k = clamp(a(0), 0.0, 87500.0) / 100000.0
        let ssf = ss.maximum(1e-9)
        let g0 = ss * k
        let g1 = max(ss - g0, 1e-9)
        let g2 = g0 * g0 / g1
        let g3 = ss * ss / g1
        let g5 = 2.0 * g3 - g2
        let g6 = g5 - g0
        let dy1 = (g5 / 2.0 - g0) * (h / 2.0) / ssf
        let (g0w, g6w) = (g0 * w / ssf, g6 * w / ssf)
        let rx = (g6w - g0w) / 2.0
        let cx = g0w + rx
        b.m(w, 0.0).arc(w, h / 2.0, 270.0, -180.0)
        if rx > 1e-9 && dy1 > 1e-9 {
            // From the bottom-right corner back up to the top-right through (g0w, h/2).
            let t0 = atan2(clamp((h / 2.0) / dy1, -1.0, 1.0), (w - cx) / rx)
            let t1 = atan2(clamp(-(h / 2.0) / dy1, -1.0, 1.0), (w - cx) / rx) + 2.0 * .pi
            b.arcCubics(center: DPoint(x: cx, y: h / 2.0), rx: rx, ry: dy1, startAngle: t0, sweepAngle: t1 - t0, tolerance: 0.05)
        }
        b.z()
        let g12 = g0 * 9598.0 / 32768.0
        let g13 = ss - g12
        let dy4 = max(ss * ss - g13 * g13, 0.0).squareRoot() * (h / 2.0) / ssf
        g = simple(b.takePath(), DRect.new(g12 * w / ssf, h / 2.0 - dy4, g0w, h / 2.0 + dy4))
    case "cloud", "cloudCallout":
        g = cloud(name, w, h, a(0), a(1))
    case "bracketPair":
        let r = ss * clamp(a(0), 0.0, 50000.0) / 1e5
        let l = Pb()
        l.m(r, h).arc(r, r, 90.0, 90.0).l(0.0, r).arc(r, r, 180.0, 90.0)
        l.m(w - r, 0.0).arc(r, r, 270.0, 90.0).l(w, h - r).arc(r, r, 0.0, 90.0)
        let f = cornerRect(w, h, [.round(r), .round(r), .round(r), .round(r)])
        g = Geometry(paths: [fillOnly(f), strokeOnly(l.takePath())], textRect: full.inset(-r * 0.29289))
    case "bracePair":
        let r = ss * clamp(a(0), 0.0, 25000.0) / 1e5
        let l = Pb()
        l.m(2.0 * r, h).arc(r, r, 90.0, 90.0).l(r, h / 2.0 + r).arc(r, r, 0.0, -90.0).arc(r, r, 90.0, -90.0).l(r, r).arc(r, r, 180.0, 90.0)
        l.m(w - 2.0 * r, 0.0)
            .arc(r, r, 270.0, 90.0)
            .l(w - r, h / 2.0 - r)
            .arc(r, r, 180.0, -90.0)
            .arc(r, r, 270.0, -90.0)
            .l(w - r, h - r)
            .arc(r, r, 0.0, 90.0)
        let f = cornerRect(w, h, [.round(r), .round(r), .round(r), .round(r)])
        g = Geometry(paths: [fillOnly(f), strokeOnly(l.takePath())], textRect: full.inset(-r * 1.2))
    case "leftBracket", "rightBracket":
        let r = min(ss * clamp(a(0), 0.0, 50000.0 * h / ss.maximum(1e-9)) / 1e5, h / 2.0)
        let l = Pb()
        l.m(w, h).arc(w, r, 90.0, 90.0).l(0.0, r).arc(w, r, 180.0, 90.0)
        var path = l.takePath()
        if name == "rightBracket" {
            path.applyAffine(DAffine(a: -1.0, b: 0.0, c: 0.0, d: 1.0, e: w, f: 0.0))
        }
        // Filled (when the shape has a fill) out to the straight side, as PowerPoint does.
        var area = path
        area.close()
        g = Geometry(paths: [fillOnly(area), strokeOnly(path)], textRect: full)
    case "leftBrace", "rightBrace":
        let r = min(ss * clamp(a(0), 0.0, 25000.0 * h / ss.maximum(1e-9)) / 1e5, h / 4.0)
        let my = h * clamp(a(1), 0.0, 100000.0) / 1e5
        let hw = w / 2.0
        let l = Pb()
        l.m(w, h).arc(hw, r, 90.0, 90.0).l(hw, my + r).arc(hw, r, 0.0, -90.0).arc(hw, r, 90.0, -90.0).l(hw, r).arc(hw, r, 180.0, 90.0)
        var path = l.takePath()
        if name == "rightBrace" {
            path.applyAffine(DAffine(a: -1.0, b: 0.0, c: 0.0, d: 1.0, e: w, f: 0.0))
        }
        var area = path
        area.close()
        g = Geometry(paths: [fillOnly(area), strokeOnly(path)], textRect: full)
    case "rightArrow":
        g = arrow(.right, w, h, a(0), a(1))
    case "leftArrow":
        g = arrow(.left, w, h, a(0), a(1))
    case "upArrow":
        g = arrow(.up, w, h, a(0), a(1))
    case "downArrow":
        g = arrow(.down, w, h, a(0), a(1))
    case "leftRightArrow":
        g = doubleArrow(vertical: false, w, h, a(0), a(1))
    case "upDownArrow":
        g = doubleArrow(vertical: true, w, h, a(0), a(1))
    case "notchedRightArrow", "stripedRightArrow":
        var ga = arrow(.right, w, h, a(0), a(1))
        let k = clamp(a(0), 0.0, 100000.0) / 1e5
        let (y1, y2) = (h / 2.0 - h * k / 2.0, h / 2.0 + h * k / 2.0)
        let dx = min(ss * max(a(1), 0.0) / 1e5, w)
        if name == "notchedRightArrow" {
            let n = dx * (k / 2.0) * 0.9
            let pts: [(Double, Double)] = [(0.0, y1), (w - dx, y1), (w - dx, 0.0), (w, h / 2.0), (w - dx, h), (w - dx, y2), (0.0, y2), (n, h / 2.0)]
            ga.paths = [fill(Pb().poly(pts).takePath())]
        } else {
            let s = ss / 32.0
            let start = 5.0 * s
            let pts: [(Double, Double)] = [(start, y1), (w - dx, y1), (w - dx, 0.0), (w, h / 2.0), (w - dx, h), (w - dx, y2), (start, y2)]
            let stripes = Pb()
            stripes.poly([(0.0, y1), (s, y1), (s, y2), (0.0, y2)])
            stripes.poly([(2.0 * s, y1), (4.0 * s, y1), (4.0 * s, y2), (2.0 * s, y2)])
            ga.paths = [fill(stripes.takePath()), fill(Pb().poly(pts).takePath())]
        }
        g = ga
    case "homePlate", "chevron":
        let v = clamp(a(0), 0.0, 100000.0 * w / ss.maximum(1e-9))
        let d = min(ss * v / 1e5, w)
        let pts: [(Double, Double)] = name == "homePlate"
            ? [(0.0, 0.0), (w - d, 0.0), (w, h / 2.0), (w - d, h), (0.0, h)]
            : [(0.0, 0.0), (w - d, 0.0), (w, h / 2.0), (w - d, h), (0.0, h), (d, h / 2.0)]
        // Text rectangles as presetShapeDefinitions give them: homePlate's runs to halfway
        // along the point; chevron's lies between the notch and the point's base (x1..x2)
        // and covers the whole width once those meet or cross.
        let text = name == "homePlate"
            ? DRect.new(0.0, 0.0, w - d / 2.0, h)
            : (w - d > d ? DRect.new(d, 0.0, w - d, h) : DRect.new(0.0, 0.0, w, h))
        g = simple(b.poly(pts).takePath(), text)
    case "quadArrow":
        let (t, hw, hl) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5, ss * clamp(a(2), 0.0, 50000.0) / 1e5)
        let (cx, cy) = (w / 2.0, h / 2.0)
        let (t2, hw2) = (t / 2.0, hw)
        let pts: [(Double, Double)] = [
            (0.0, cy), (hl, cy - hw2), (hl, cy - t2), (cx - t2, cy - t2), (cx - t2, hl), (cx - hw2, hl),
            (cx, 0.0), (cx + hw2, hl), (cx + t2, hl), (cx + t2, cy - t2), (w - hl, cy - t2), (w - hl, cy - hw2),
            (w, cy), (w - hl, cy + hw2), (w - hl, cy + t2), (cx + t2, cy + t2), (cx + t2, h - hl), (cx + hw2, h - hl),
            (cx, h), (cx - hw2, h - hl), (cx - t2, h - hl), (cx - t2, cy + t2), (hl, cy + t2), (hl, cy + hw2),
        ]
        g = simple(b.poly(pts).takePath(), DRect.new(cx - t2, cy - t2, cx + t2, cy + t2))
    case "leftRightUpArrow":
        let (t, hw, hl) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5, ss * clamp(a(2), 0.0, 50000.0) / 1e5)
        let cx = w / 2.0
        let by = h - hw // horizontal shaft centre
        let pts: [(Double, Double)] = [
            (0.0, by), (hl, by - hw), (hl, by - t / 2.0), (cx - t / 2.0, by - t / 2.0), (cx - t / 2.0, hl),
            (cx - hw, hl), (cx, 0.0), (cx + hw, hl), (cx + t / 2.0, hl), (cx + t / 2.0, by - t / 2.0),
            (w - hl, by - t / 2.0), (w - hl, by - hw), (w, by), (w - hl, h), (w - hl, by + t / 2.0),
            (hl, by + t / 2.0), (hl, h),
        ]
        g = simple(b.poly(pts).takePath(), DRect.new(hl, by - t / 2.0, w - hl, by + t / 2.0))
    case "leftUpArrow", "bentUpArrow":
        let (t, hw, hl) = (ss * clamp(a(0), 0.0, 50000.0) / 1e5, ss * clamp(a(1), 0.0, 50000.0) / 1e5, ss * clamp(a(2), 0.0, 50000.0) / 1e5)
        let pts: [(Double, Double)]
        if name == "leftUpArrow" {
            let cx = w - hw
            let cy = h - hw
            pts = [
                (0.0, cy), (hl, cy - hw), (hl, cy - t / 2.0), (cx - t / 2.0, cy - t / 2.0), (cx - t / 2.0, hl),
                (cx - hw, hl), (cx, 0.0), (w, hl), (cx + t / 2.0, hl), (cx + t / 2.0, cy + t / 2.0),
                (hl, cy + t / 2.0), (hl, h),
            ]
        } else {
            let cx = w - hw
            pts = [
                (0.0, h - t), (cx - t / 2.0, h - t), (cx - t / 2.0, hl), (cx - hw, hl), (cx, 0.0),
                (w, hl), (cx + t / 2.0, hl), (cx + t / 2.0, h), (0.0, h),
            ]
        }
        g = simple(b.poly(pts).takePath(), full)
    case "bentArrow":
        let (t, hw, hl, r) = (
            ss * clamp(a(0), 0.0, 50000.0) / 1e5,
            ss * clamp(a(1), 0.0, 50000.0) / 1e5,
            ss * clamp(a(2), 0.0, 50000.0) / 1e5,
            ss * clamp(a(3), 0.0, 100000.0) / 1e5
        )
        let cy = hw // head centre line
        let ro = max(r, t)
        let ri = max(ro - t, 0.0)
        b.m(0.0, h)
            .l(0.0, cy - t / 2.0 + ro)
            .arc(ro, ro, 180.0, 90.0)
            .l(w - hl, cy - t / 2.0)
            .l(w - hl, 0.0)
            .l(w, cy)
            .l(w - hl, 2.0 * hw)
            .l(w - hl, cy + t / 2.0)
        b.l(t + ri, cy + t / 2.0)
        if ri > 0.0 {
            b.arc(ri, ri, 270.0, -90.0)
        }
        b.l(t, h).z()
        g = simple(b.takePath(), full)
    case "uturnArrow":
        let (t, hw, hl, r) = (
            ss * clamp(a(0), 0.0, 25000.0) / 1e5,
            ss * clamp(a(1), 0.0, 25000.0) / 1e5,
            ss * clamp(a(2), 0.0, 25000.0) / 1e5,
            ss * clamp(a(3), 0.0, 100000.0) / 1e5
        )
        let hy = max(h * clamp(a(4), 0.0, 100000.0) / 1e5, hl + t)
        let ax = w - hw // arrow shaft centre x
        let ro = min(max(r, t), (ax + t / 2.0) / 2.0)
        let ri = max(ro - t, 0.0)
        b.m(0.0, h).l(0.0, ro).arc(ro, ro, 180.0, 90.0).l(ax + t / 2.0 - ro, 0.0).arc(ro, ro, 270.0, 90.0)
        b.l(ax + t / 2.0, hy - hl).l(w, hy - hl).l(ax, hy).l(ax - hw, hy - hl).l(ax - t / 2.0, hy - hl).l(ax - t / 2.0, ro)
        if ri > 0.0 {
            b.arc(ri, ri, 0.0, -90.0)
        }
        b.l(t + ri, t)
        if ri > 0.0 {
            b.arc(ri, ri, 270.0, -90.0)
        }
        b.l(t, h).z()
        g = simple(b.takePath(), full)
    case "rightArrowCallout", "leftArrowCallout", "upArrowCallout", "downArrowCallout":
        let d: ArrowDir
        switch name {
        case "rightArrowCallout": d = .right
        case "leftArrowCallout": d = .left
        case "upArrowCallout": d = .up
        default: d = .down
        }
        let (l, t) = lenThick(d, w, h)
        let ss2 = min(l, t)
        let shaft = ss2 * clamp(a(0), 0.0, 100000.0) / 1e5
        let head = ss2 * clamp(a(1), 0.0, 100000.0) / 1e5
        let hl = ss2 * clamp(a(2), 0.0, 100000.0) / 1e5
        let boxl = min(l * clamp(a(3), 0.0, 100000.0) / 1e5, l - hl)
        let c = t / 2.0
        let pts: [(Double, Double)] = [
            (0.0, 0.0), (boxl, 0.0), (boxl, c - shaft / 2.0), (l - hl, c - shaft / 2.0),
            (l - hl, c - head), (l, c), (l - hl, c + head), (l - hl, c + shaft / 2.0),
            (boxl, c + shaft / 2.0), (boxl, t), (0.0, t),
        ]
        let oriented = orient(d, w, h, pts)
        let tr = orient(d, w, h, [(0.0, 0.0), (boxl, t)])
        g = simple(b.poly(oriented).takePath(), DRect.fromPoints(DPoint(x: tr[0].0, y: tr[0].1), DPoint(x: tr[1].0, y: tr[1].1)).abs())
    case "mathPlus", "mathMinus", "mathEqual", "mathDivide", "mathMultiply", "mathNotEqual":
        g = math(name, w, h, a(0), a(1), a(2))
    case "flowChartPredefinedProcess":
        let r = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]).takePath()
        let l = Pb()
        l.m(w / 8.0, 0.0).l(w / 8.0, h).m(w * 7.0 / 8.0, 0.0).l(w * 7.0 / 8.0, h)
        g = Geometry(paths: [fill(r), strokeOnly(l.takePath())], textRect: DRect.new(w / 8.0, 0.0, w * 7.0 / 8.0, h))
    case "flowChartInternalStorage":
        let r = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]).takePath()
        let l = Pb()
        l.m(w / 8.0, 0.0).l(w / 8.0, h).m(0.0, h / 8.0).l(w, h / 8.0)
        g = Geometry(paths: [fill(r), strokeOnly(l.takePath())], textRect: DRect.new(w / 8.0, h / 8.0, w, h))
    case "flowChartDocument":
        func u(_ x: Double, _ y: Double) -> (Double, Double) { (w * x / 21600.0, h * y / 21600.0) }
        let (p1, p2, p3, p4) = (u(21600.0, 17322.0), u(10800.0, 17322.0), u(10800.0, 23922.0), u(0.0, 20172.0))
        b.m(0.0, 0.0).l(w, 0.0).l(p1.0, p1.1).c(p2.0, p2.1, p3.0, p3.1, p4.0, p4.1).z()
        g = simple(b.takePath(), DRect.new(0.0, 0.0, w, h * 17322.0 / 21600.0))
    case "flowChartMultidocument":
        // ECMA-376 multidocument (21600ths): two back pages peeking out above and right of
        // the front one; the back pages' edges are outlined only where they show.
        func x(_ v: Double) -> Double { w * v / 21600.0 }
        func y(_ v: Double) -> Double { h * v / 21600.0 }
        func front(_ target: Pb) {
            target.m(0.0, y(20782.0))
                .c(x(9298.0), y(23542.0), x(9298.0), y(18022.0), x(18595.0), y(18022.0))
                .l(x(18595.0), y(3675.0))
                .l(0.0, y(3675.0))
                .z()
        }
        func mid(_ target: Pb) {
            target.m(x(1532.0), y(3675.0)).l(x(1532.0), y(1815.0)).l(x(20000.0), y(1815.0)).l(x(20000.0), y(16252.0))
            target.c(x(19298.0), y(16252.0), x(18595.0), y(16352.0), x(18595.0), y(16352.0))
        }
        func back(_ target: Pb) {
            target.m(x(2972.0), y(1815.0)).l(x(2972.0), 0.0).l(w, 0.0).l(w, y(14392.0))
            target.c(x(20800.0), y(14392.0), x(20000.0), y(14467.0), x(20000.0), y(14467.0))
        }
        let area = Pb()
        front(area)
        mid(area)
        area.l(x(18595.0), y(3675.0)).z()
        back(area)
        area.l(x(20000.0), y(1815.0)).z()
        let outline = Pb()
        outline.m(0.0, y(3675.0)).l(x(18595.0), y(3675.0)).l(x(18595.0), y(18022.0))
        outline.c(x(9298.0), y(18022.0), x(9298.0), y(23542.0), 0.0, y(20782.0)).z()
        mid(outline)
        back(outline)
        g = Geometry(
            paths: [fillOnly(area.takePath()), strokeOnly(outline.takePath())],
            textRect: DRect.new(0.0, y(3675.0), x(18595.0), y(17322.0))
        )
    case "flowChartTerminator":
        let rx = min(w * 0.16, w / 2.0)
        b.m(rx, 0.0).l(w - rx, 0.0).arc(rx, h / 2.0, 270.0, 180.0).l(rx, h).arc(rx, h / 2.0, 90.0, 180.0).z()
        g = simple(b.takePath(), DRect.new(rx * 0.3, h * 0.15, w - rx * 0.3, h * 0.85))
    case "flowChartManualInput":
        g = simple(b.poly([(0.0, h / 5.0), (w, 0.0), (w, h), (0.0, h)]).takePath(), DRect.new(0.0, h / 5.0, w, h))
    case "flowChartOffpageConnector":
        g = simple(b.poly([(0.0, 0.0), (w, 0.0), (w, h * 0.8), (w / 2.0, h), (0.0, h * 0.8)]).takePath(), DRect.new(0.0, 0.0, w, h * 0.8))
    case "flowChartPunchedCard":
        g = simple(b.poly([(w * 0.2, 0.0), (w, 0.0), (w, h), (0.0, h), (0.0, h * 0.2)]).takePath(), DRect.new(0.0, h * 0.2, w, h))
    case "flowChartPunchedTape":
        // ECMA-376: each long edge is two half-ellipses a quarter of the width wide and a
        // tenth of the height deep, one bulging in and one out.
        let (rx, ry) = (w / 4.0, h / 10.0)
        b.m(0.0, ry).arc(rx, ry, 180.0, -180.0).arc(rx, ry, 180.0, 180.0).l(w, h - ry).arc(rx, ry, 0.0, -180.0).arc(rx, ry, 0.0, 180.0).z()
        g = simple(b.takePath(), DRect.new(0.0, h / 5.0, w, h * 0.8))
    case "flowChartSummingJunction", "flowChartOr":
        let e = Pb().ellipse(w / 2.0, h / 2.0, w / 2.0, h / 2.0).takePath()
        let l = Pb()
        if name == "flowChartOr" {
            l.m(w / 2.0, 0.0).l(w / 2.0, h).m(0.0, h / 2.0).l(w, h / 2.0)
        } else {
            let (dx, dy) = (w / 2.0 / 2.0.squareRoot(), h / 2.0 / 2.0.squareRoot())
            l.m(w / 2.0 - dx, h / 2.0 - dy).l(w / 2.0 + dx, h / 2.0 + dy).m(w / 2.0 + dx, h / 2.0 - dy).l(w / 2.0 - dx, h / 2.0 + dy)
        }
        g = Geometry(paths: [fill(e), strokeOnly(l.takePath())], textRect: DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355))
    case "flowChartCollate":
        g = simple(b.poly([(0.0, 0.0), (w, 0.0), (0.0, h), (w, h)]).takePath(), DRect.new(w / 4.0, h / 4.0, w * 0.75, h * 0.75))
    case "flowChartOnlineStorage":
        let rx = w / 6.0
        b.m(rx, 0.0).l(w, 0.0).arc(rx, h / 2.0, 270.0, -180.0).l(rx, h).arc(rx, h / 2.0, 90.0, 180.0).z()
        g = simple(b.takePath(), DRect.new(rx, 0.0, w - rx, h))
    case "flowChartDelay":
        b.m(0.0, 0.0).l(w / 2.0, 0.0).arc(w / 2.0, h / 2.0, 270.0, 180.0).l(0.0, h).z()
        g = simple(b.takePath(), DRect.new(0.0, h * 0.15, w * 0.85, h * 0.85))
    case "flowChartMagneticTape":
        b.m(w / 2.0, h).arc(w / 2.0, h / 2.0, 90.0, 90.0).arc(w / 2.0, h / 2.0, 180.0, 90.0).arc(w / 2.0, h / 2.0, 270.0, 90.0).arc(w / 2.0, h / 2.0, 0.0, 45.0)
        let p = b.cur
        b.l(w, p.y).l(w, h).z()
        g = simple(b.takePath(), DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355))
    case "flowChartDisplay":
        let rx = w / 6.0
        b.m(0.0, h / 2.0).l(rx, 0.0).l(w - rx, 0.0).arc(rx, h / 2.0, 270.0, 180.0).l(rx, h).z()
        g = simple(b.takePath(), DRect.new(rx, 0.0, w - rx, h))
    case "star4", "star5", "star6", "star7", "star8", "star10", "star12", "star16", "star24", "star32":
        let n = Int(name.hasPrefix("star") ? String(name.dropFirst(4)) : name) ?? 5
        let v = clamp(a(0), 0.0, 50000.0)
        let inner = v / 50000.0
        let text = starTextRect(n, w, h, inner) ?? full.inset(-ss * (0.5 - inner * 0.5) * 0.5)
        g = simple(b.poly(star(n, w, h, inner)).takePath(), text)
    case "irregularSeal1":
        // ECMA-376 irregularSeal1 ("Explosion: 8 Points"), in 21600ths of the box.
        let pts = specPts([
            (10800, 5800), (14522, 0), (14155, 5325), (18380, 4457), (16702, 7315), (21097, 8137),
            (17607, 10475), (21600, 13290), (16837, 12942), (18145, 18095), (14020, 14457), (13247, 19737),
            (10532, 14935), (8485, 21600), (7715, 15627), (4762, 17617), (5667, 13937), (135, 14587),
            (3722, 11775), (0, 8615), (4627, 7617), (370, 2295), (7312, 6320), (8352, 2295),
        ], w, h)
        g = simple(b.poly(pts).takePath(), DRect.new(w * 4627.0 / 21600.0, h * 6320.0 / 21600.0, w * 16702.0 / 21600.0, h * 13937.0 / 21600.0))
    case "irregularSeal2":
        // ECMA-376 irregularSeal2 ("Explosion: 14 Points"), in 21600ths of the box.
        let pts = specPts([
            (11462, 4342), (14790, 0), (14525, 5777), (18007, 3172), (16380, 6532), (21600, 6645),
            (16985, 9402), (18270, 11290), (16380, 12310), (18877, 15632), (14640, 14350), (14942, 17370),
            (12180, 15935), (11612, 18842), (9872, 17370), (8700, 19712), (7527, 18125), (4917, 21600),
            (4805, 18240), (1285, 17825), (3330, 15370), (0, 12877), (3935, 11592), (1172, 8270),
            (5372, 7817), (4502, 3625), (8550, 6382), (9722, 1887),
        ], w, h)
        g = simple(b.poly(pts).takePath(), DRect.new(w * 5372.0 / 21600.0, h * 6382.0 / 21600.0, w * 14640.0 / 21600.0, h * 15935.0 / 21600.0))
    case "ribbon", "ribbon2":
        g = ribbon(up: name == "ribbon2", w, h, a(0), a(1))
    case "verticalScroll", "horizontalScroll":
        g = scroll(vertical: name == "verticalScroll", w, h, a(0))
    case "wave", "doubleWave":
        // ECMA-376 wave / doubleWave: the top and bottom edges are cubic waves (one or two
        // periods) of amplitude adj1, shifted sideways by adj2.
        let a1c = clamp(a(0), 0.0, name == "wave" ? 20000.0 : 12500.0)
        let a2c = clamp(a(1), -10000.0, 10000.0)
        let y1 = h * a1c / 100000.0
        let dy2 = y1 * 10.0 / 3.0
        let (y2, y3, y4) = (y1 - dy2, y1 + dy2, h - y1)
        let (y5, y6) = (y4 - dy2, y4 + dy2)
        let of2 = w * a2c / 50000.0
        let dx2 = min(of2, 0.0)
        let dxr = max(of2, 0.0)
        let (x2, xr, xl, x10) = (-dx2, w - dxr, dxr, w + dx2)
        let textY = h * a1c / 50000.0
        if name == "wave" {
            let dx3 = (dx2 + xr) / 3.0
            let (x3, x7) = (x2 + dx3, xl + dx3)
            let (x4, x8) = ((x3 + xr) / 2.0, (x7 + x10) / 2.0)
            b.m(x2, y1).c(x3, y2, x4, y3, xr, y1).l(x10, y4).c(x8, y6, x7, y5, xl, y4).z()
        } else {
            let (dx3, dx4) = ((dx2 + xr) / 6.0, (dx2 + xr) / 3.0)
            let (x3, x4, x5) = (x2 + dx3, x2 + dx4, (x2 + xr) / 2.0)
            let x6 = x5 + dx3
            let x7 = (x6 + xr) / 2.0
            let (x10b, x11, x12) = (xl + dx3, xl + dx4, (xl + x10) / 2.0)
            let x13 = x12 + dx3
            let x14 = (x13 + x10) / 2.0
            b.m(x2, y1).c(x3, y2, x4, y3, x5, y1).c(x6, y2, x7, y3, xr, y1).l(x10, y4)
            b.c(x14, y6, x13, y5, x12, y4).c(x11, y6, x10b, y5, xl, y4).z()
        }
        g = simple(b.takePath(), DRect.new(max(x2, xl), textY, min(xr, x10), h - textY))
    case "wedgeRectCallout", "wedgeRoundRectCallout":
        let r = name == "wedgeRoundRectCallout" ? ss * clamp(a(2), 0.0, 50000.0) / 1e5 : 0.0
        g = wedgeRect(w, h, a(0), a(1), r)
    case "wedgeEllipseCallout":
        let tip = DPoint(x: w / 2.0 + w * a(0) / 1e5, y: h / 2.0 + h * a(1) / 1e5)
        let ang = atan2(tip.y - h / 2.0, tip.x - w / 2.0).toDegrees
        let s = vis(ang + 10.0, w / 2.0, h / 2.0)
        let p0 = DPoint(x: w / 2.0 + w / 2.0 * cos(s.toRadians), y: h / 2.0 + h / 2.0 * sin(s.toRadians))
        let e = vis(ang - 10.0, w / 2.0, h / 2.0)
        var sw = e - s
        if sw <= 0.0 {
            sw += 360.0
        }
        b.m(p0.x, p0.y).arc(w / 2.0, h / 2.0, s, sw).l(tip.x, tip.y).z()
        g = simple(b.takePath(), DRect.new(w * 0.14645, h * 0.14645, w * 0.85355, h * 0.85355))
    case "borderCallout1":
        let r = Pb().poly([(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]).takePath()
        let p1 = (w * a(1) / 1e5, h * a(0) / 1e5)
        let p2 = (w * a(3) / 1e5, h * a(2) / 1e5)
        let l = Pb().m(p1.0, p1.1).l(p2.0, p2.1).takePath()
        g = Geometry(paths: [fill(r), strokeOnly(l)], textRect: full)
    case "line", "straightConnector1":
        let l = Pb().m(0.0, 0.0).l(w, h).takePath()
        g = Geometry(paths: [strokeOnly(l)], textRect: full)
    case "bentConnector2":
        let l = Pb().m(0.0, 0.0).l(w, 0.0).l(w, h).takePath()
        g = Geometry(paths: [strokeOnly(l)], textRect: full)
    case "bentConnector3", "bentConnector4", "bentConnector5":
        let x = w * a(0) / 1e5
        let l = Pb().m(0.0, 0.0).l(x, 0.0).l(x, h).l(w, h).takePath()
        g = Geometry(paths: [strokeOnly(l)], textRect: full)
    case "curvedConnector2", "curvedConnector3", "curvedConnector4", "curvedConnector5":
        let x = w * (name == "curvedConnector2" ? 100000.0 : a(0)) / 1e5
        let l = Pb().m(0.0, 0.0).c(x / 2.0, 0.0, x, h / 4.0, x, h / 2.0).c(x, h * 0.75, (x + w) / 2.0, h, w, h).takePath()
        g = Geometry(paths: [strokeOnly(l)], textRect: full)
    default:
        return presetBuildExtra(name, w, h, a)
    }
    return g
}
