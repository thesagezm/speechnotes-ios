// PresetShapesExtra.swift — more preset outlines: line callouts, arrow callouts, curved and
// circular arrows, curved ribbons, gears, tabs and chart markers.
//
// Ported from DeckCraft's geom crate `preset/extra.rs` (github.com/storytold/deckcraft
// @ a0eeb34, MIT/Apache-2.0). Like the rest of the preset module, every outline is DeckCraft's
// own construction, fitted to how the shapes look and to what their adjust values mean.
// Handles and glue sites are editor-only and not ported.

import Foundation

/// Builds the presets this module knows; `nil` for any other name.
func presetBuildExtra(_ name: String, _ w: Double, _ h: Double, _ a: (Int) -> Double) -> Geometry? {
    let ss = min(w, h)
    let full = DRect.new(0.0, 0.0, w, h)
    let b = Pb()
    let g: Geometry
    switch name {
    case "lineInv":
        let l = b.m(0.0, h).l(w, 0.0).takePath()
        g = Geometry(paths: [strokeOnly(l)], textRect: full)
    case "nonIsoscelesTrapezoid":
        let maxV = 50000.0 * w / ss.rustMax(1e-9)
        let (v1, v2) = (clamp(a(0), 0.0, maxV), clamp(a(1), 0.0, maxV))
        let (d1, d2) = (ss * v1 / 1e5, ss * v2 / 1e5)
        g = simple(b.poly([(0.0, h), (d1, 0.0), (w - d2, 0.0), (w, h)]).takePath(), DRect.new(d1 * 0.66, h * 0.2, w - d2 * 0.66, h))
    case "pieWedge":
        b.m(0.0, h).arc(w, h, 180.0, 90.0).l(w, h).z()
        g = simple(b.takePath(), DRect.new(w * 0.29289, h * 0.29289, w, h))
    case "flowChartOfflineStorage":
        let tri = b.poly([(0.0, 0.0), (w, 0.0), (w / 2.0, h)]).takePath()
        let bar = Pb().m(w * 0.4, h * 0.8).l(w * 0.6, h * 0.8).takePath()
        g = Geometry(paths: [fill(tri), strokeOnly(bar)], textRect: DRect.new(w / 4.0, 0.0, w * 0.75, h * 0.8))
    case "chartX", "chartStar", "chartPlus":
        let body = cornerRect(w, h, [.square, .square, .square, .square])
        let l = Pb()
        if name != "chartPlus" {
            l.m(0.0, 0.0).l(w, h).m(0.0, h).l(w, 0.0)
        }
        if name != "chartX" {
            l.m(w / 2.0, 0.0).l(w / 2.0, h)
        }
        if name == "chartPlus" {
            l.m(0.0, h / 2.0).l(w, h / 2.0)
        }
        g = Geometry(paths: [fillOnly(body), strokeOnly(l.takePath())], textRect: full)
    case "cornerTabs", "squareTabs", "plaqueTabs":
        // Each tab's size is a twentieth of the diagonal.
        let d = min(min((w * w + h * h).squareRoot() / 20.0, w / 2.0), h / 2.0)
        switch name {
        case "cornerTabs":
            b.poly([(0.0, 0.0), (d, 0.0), (0.0, d)])
            b.poly([(w - d, 0.0), (w, 0.0), (w, d)])
            b.poly([(w, h - d), (w, h), (w - d, h)])
            b.poly([(0.0, h - d), (d, h), (0.0, h)])
        case "squareTabs":
            b.poly([(0.0, 0.0), (d, 0.0), (d, d), (0.0, d)])
            b.poly([(w - d, 0.0), (w, 0.0), (w, d), (w - d, d)])
            b.poly([(w - d, h - d), (w, h - d), (w, h), (w - d, h)])
            b.poly([(0.0, h - d), (d, h - d), (d, h), (0.0, h)])
        default:
            if d > 0.0 {
                b.m(0.0, 0.0).l(d, 0.0).arc(d, d, 0.0, 90.0).z()
                b.m(w, 0.0).l(w, d).arc(d, d, 90.0, 90.0).z()
                b.m(w, h).l(w - d, h).arc(d, d, 180.0, 90.0).z()
                b.m(0.0, h).l(0.0, h - d).arc(d, d, 270.0, 90.0).z()
            } else {
                b.m(0.0, 0.0).z()
            }
        }
        g = Geometry(paths: [fill(b.takePath())], textRect: full.inset(-d))
    case "callout1", "callout2", "callout3", "accentCallout1", "accentCallout2", "accentCallout3",
         "borderCallout2", "borderCallout3", "accentBorderCallout1", "accentBorderCallout2", "accentBorderCallout3":
        let n: Int
        switch name.last {
        case "2": n = 2
        case "3": n = 3
        default: n = 1
        }
        g = lineCallout(w, h, a, n + 1, name.hasPrefix("accent"), name.contains("order"))
    case "leftRightArrowCallout", "upDownArrowCallout":
        let vertical = name == "upDownArrowCallout"
        let (l, t) = vertical ? (h, w) : (w, h)
        let ss2 = min(l, t)
        let head = min(ss2 * max(a(1), 0.0) / 1e5, t / 2.0)
        let shaft = min(ss2 * max(a(0), 0.0) / 1e5, head * 2.0)
        let hl = min(ss2 * max(a(2), 0.0) / 1e5, l / 2.0)
        let boxl = min(l * max(a(3), 0.0) / 1e5, l - 2.0 * hl)
        let (c, b0, b1) = (t / 2.0, (l - boxl) / 2.0, (l + boxl) / 2.0)
        let pts: [(Double, Double)] = [
            (0.0, c), (hl, c - head), (hl, c - shaft / 2.0), (b0, c - shaft / 2.0), (b0, 0.0), (b1, 0.0),
            (b1, c - shaft / 2.0), (l - hl, c - shaft / 2.0), (l - hl, c - head), (l, c), (l - hl, c + head),
            (l - hl, c + shaft / 2.0), (b1, c + shaft / 2.0), (b1, t), (b0, t), (b0, c + shaft / 2.0),
            (hl, c + shaft / 2.0), (hl, c + head),
        ]
        let d: ArrowDir = vertical ? .down : .right
        let oriented = orient(d, w, h, pts)
        let tr = orient(d, w, h, [(b0, 0.0), (b1, t)])
        g = simple(b.poly(oriented).takePath(), DRect.fromPoints(DPoint(x: tr[0].0, y: tr[0].1), DPoint(x: tr[1].0, y: tr[1].1)).abs())
    case "quadArrowCallout":
        let head = min(ss * max(a(1), 0.0) / 1e5, ss / 2.0)
        let shaft = min(ss * max(a(0), 0.0) / 1e5, head * 2.0)
        let hl = min(ss * max(a(2), 0.0) / 1e5, ss / 2.0)
        let k = clamp(a(3), 0.0, 100000.0) / 1e5
        let (bw, bh) = (max(min(w * k, w - 2.0 * hl), shaft), max(min(h * k, h - 2.0 * hl), shaft))
        let (cx, cy) = (w / 2.0, h / 2.0)
        let (bx0, bx1, by0, by1) = (cx - bw / 2.0, cx + bw / 2.0, cy - bh / 2.0, cy + bh / 2.0)
        let (s2, hd) = (shaft / 2.0, head)
        let pts: [(Double, Double)] = [
            (0.0, cy), (hl, cy - hd), (hl, cy - s2), (bx0, cy - s2), (bx0, by0), (cx - s2, by0),
            (cx - s2, hl), (cx - hd, hl), (cx, 0.0), (cx + hd, hl), (cx + s2, hl), (cx + s2, by0),
            (bx1, by0), (bx1, cy - s2), (w - hl, cy - s2), (w - hl, cy - hd), (w, cy), (w - hl, cy + hd),
            (w - hl, cy + s2), (bx1, cy + s2), (bx1, by1), (cx + s2, by1), (cx + s2, h - hl), (cx + hd, h - hl),
            (cx, h), (cx - hd, h - hl), (cx - s2, h - hl), (cx - s2, by1), (bx0, by1), (bx0, cy + s2),
            (hl, cy + s2), (hl, cy + hd),
        ]
        g = simple(b.poly(pts).takePath(), DRect.new(bx0, by0, bx1, by1))
    case "curvedRightArrow", "curvedLeftArrow", "curvedUpArrow", "curvedDownArrow":
        g = curvedArrow(name, w, h, a(0), a(1), a(2))
    case "swooshArrow":
        g = swoosh(w, h, a(0), a(1))
    case "ellipseRibbon", "ellipseRibbon2":
        g = ellipseRibbon(up: name == "ellipseRibbon2", w, h, a(0), a(1), a(2))
    case "leftRightRibbon":
        g = leftRightRibbon(w, h, a(0), a(1), a(2))
    case "gear6", "gear9":
        g = gear(name == "gear6" ? 6 : 9, w, h, a(0), a(1))
    case "funnel":
        g = funnel(w, h)
    case "circularArrow", "leftCircularArrow", "leftRightCircularArrow":
        g = circularArrow(name, w, h, [a(0), a(1), a(2), a(3), a(4)])
    default:
        return nil
    }
    return g
}

// MARK: - circular arrows

/// An ellipse-centred frame for the circular arrows: the band's middle runs on the ellipse
/// `(rx, ry)`, its edges `th/2` either side.
struct Ring {
    let c: DPoint
    let rx: Double
    let ry: Double
    let th: Double
    let hw: Double

    /// The point at visual angle `deg` on the ellipse grown by `d`.
    func at(_ deg: Double, _ d: Double) -> DPoint {
        let (ax, ay) = (max(rx + d, 0.0), max(ry + d, 0.0))
        let t = vis(deg, ax, ay).toRadians
        return DPoint(x: c.x + ax * cos(t), y: c.y + ay * sin(t))
    }

    /// Parametric angle (degrees) of `p` on the ellipse grown by `d`.
    func param(_ p: DPoint, _ d: Double) -> Double {
        let (ax, ay) = (max(rx + d, 1e-9), max(ry + d, 1e-9))
        return atan2((p.y - c.y) / ay, (p.x - c.x) / ax).toDegrees
    }

    /// Where the line `b + s·u` meets the ellipse grown by `d`, taking the crossing nearest `b`
    /// on the side `sign` (+1 outwards, −1 inwards).
    func cross(_ b: DPoint, _ u: DVec, _ d: Double, _ sign: Double) -> DPoint {
        let (ax, ay) = (max(rx + d, 1e-9), max(ry + d, 1e-9))
        let (px, py) = ((b.x - c.x) / ax, (b.y - c.y) / ay)
        let (ux, uy) = (u.dx / ax, u.dy / ay)
        let qa = ux * ux + uy * uy
        let qb = 2.0 * (px * ux + py * uy)
        let qc = px * px + py * py - 1.0
        let disc = qb * qb - 4.0 * qa * qc
        if qa < 1e-18 || disc < 0.0 {
            // The line misses (a long head on a thin ring): the edge then carries on from the
            // base centre itself, as the reference does.
            return b
        }
        let r = disc.squareRoot()
        let (s0, s1) = ((-qb - r) / (2.0 * qa), (-qb + r) / (2.0 * qa))
        let s: Double
        if sign > 0.0 {
            s = s0 >= 0.0 ? s0 : s1
        } else {
            s = s1 <= 0.0 ? s1 : s0
        }
        return b + u * s
    }

    /// An arrow head whose base centre sits on the middle ellipse at `base` degrees and whose tip
    /// sits there at `base + sweep`. The base runs along the line from the centre to the tip.
    /// Returns (band outer edge, outer wing, tip, inner wing, band inner edge).
    func head(_ base: Double, _ sweep: Double) -> [DPoint] {
        let b = at(base, 0.0)
        let tip = at(base + sweep, 0.0)
        let d = tip - c
        let u = d.hypot > 1e-12 ? d / d.hypot : DVec(dx: 1.0, dy: 0.0)
        let half = th / 2.0
        return [cross(b, u, half, 1.0), b + u * hw, tip, b - u * hw, cross(b, u, -half, -1.0)]
    }
}

/// Sweep (degrees) from `a` to `b` turning one way: positive when `dir > 0`.
func turn(_ a: Double, _ b: Double, _ dir: Double) -> Double {
    dir > 0.0 ? remEuclid(b - a, 360.0) : -remEuclid(a - b, 360.0)
}

/// The circular arrows: a band along an ellipse with one head (`circularArrow` clockwise,
/// `leftCircularArrow` anticlockwise) or a head at each end (`leftRightCircularArrow`).
/// Adjusts: band thickness, head sweep (degrees), end angle, start angle, head half-width.
func circularArrow(_ name: String, _ w: Double, _ h: Double, _ a: [Double]) -> Geometry {
    let ss = min(w, h)
    if ss <= 0.0 {
        return simple(cornerRect(w, h, [.square, .square, .square, .square]), DRect.new(0.0, 0.0, w, h))
    }
    let a5 = clamp(a[4], 0.0, 25000.0)
    let hw = ss * a5 / 1e5
    let th = ss * clamp(a[0], 0.0, 2.0 * a5) / 1e5
    let ring = Ring(c: DPoint(x: w / 2.0, y: h / 2.0), rx: max(w / 2.0 - hw, th / 2.0), ry: max(h / 2.0 - hw, th / 2.0), th: th, hw: hw)
    func deg(_ v: Double) -> Double { (v / 60000.0).truncatingRemainder(dividingBy: 360.0) }
    let (sweep, end, start) = (deg(a[1]), deg(a[2]), deg(a[3]))
    let half = th / 2.0
    let b = Pb()
    // Arcs of the ellipse grown by `d`, drawn on from the current point (which is on it except in
    // the degenerate case above, where the arc shifts with it like the reference's).
    func edgeArc(_ target: Pb, _ from: DPoint, _ to: DPoint, _ d: Double, _ dir: Double) {
        let (ax, ay) = (max(ring.rx + d, 0.0), max(ring.ry + d, 0.0))
        let (s, e) = (ring.param(from, d), ring.param(to, d))
        target.arc(ax, ay, s, turn(s, e, dir))
    }
    func outerArc(_ target: Pb, _ from: DPoint, _ to: DPoint, _ dir: Double) { edgeArc(target, from, to, half, dir) }
    func innerArc(_ target: Pb, _ from: DPoint, _ to: DPoint, _ dir: Double) { edgeArc(target, from, to, -half, dir) }
    if name == "leftRightCircularArrow" {
        let hs = ring.head(start, -sweep)
        let he = ring.head(end, sweep)
        b.m(hs[0].x, hs[0].y)
        outerArc(b, hs[0], he[0], 1.0)
        b.l(he[1].x, he[1].y).l(he[2].x, he[2].y).l(he[3].x, he[3].y).l(he[4].x, he[4].y)
        innerArc(b, he[4], hs[4], -1.0)
        b.l(hs[3].x, hs[3].y).l(hs[2].x, hs[2].y).l(hs[1].x, hs[1].y).z()
    } else {
        let dir = name == "circularArrow" ? 1.0 : -1.0
        let he = ring.head(end, sweep)
        let (o0, i0) = (ring.at(start, half), ring.at(start, -half))
        b.m(o0.x, o0.y)
        outerArc(b, o0, he[0], dir)
        b.l(he[1].x, he[1].y).l(he[2].x, he[2].y).l(he[3].x, he[3].y).l(he[4].x, he[4].y)
        innerArc(b, he[4], i0, -dir)
        b.z()
    }
    return simple(b.takePath(), DRect.new(0.0, 0.0, w, h))
}

/// A funnel: an elliptical rim (with an open mouth) across the top quarter, and straight sides
/// down to a small rounded spout. The side lines leave the rim and meet the spout at fixed
/// angles, fitted to the reference look.
func funnel(_ w: Double, _ h: Double) -> Geometry {
    let RIM = 173.0    // where the left side leaves the rim, degrees on the rim ellipse
    let SPOUT = 163.4  // where it meets the spout, degrees on the spout ellipse
    let ss = min(w, h)
    let (cx, rimY) = (w / 2.0, h / 4.0)
    let (sx, sy) = (w / 8.0, h / 15.0)
    let spoutY = h - sy
    func at(_ rx: Double, _ ry: Double, _ cy: Double, _ deg: Double) -> DPoint {
        let t = deg.toRadians
        return DPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
    }
    let p0 = at(cx, rimY, rimY, RIM)
    let p1 = at(sx, sy, spoutY, 180.0 - SPOUT)
    let b = Pb()
    b.m(p0.x, p0.y).arc(cx, rimY, RIM, 540.0 - 2.0 * RIM)
    b.l(p1.x, p1.y).arc(sx, sy, 180.0 - SPOUT, 2.0 * SPOUT - 180.0).z()
    let d = ss / 20.0
    b.ellipse(cx, rimY, max(cx - d, 0.0), max(rimY - d, 0.0))
    return Geometry(paths: [fillEO(b.takePath())], textRect: DRect.new(w / 4.0, h / 2.0, w * 0.75, h - sy))
}

/// A gear: an elliptical body with `n` teeth, the first pointing straight up. Each tooth leaves
/// the body at two points an equal angle either side of its centre, and its tip corners sit a
/// tooth height further out along the body's normal and a flank lean further in.
func gear(_ n: Int, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
    let ss = min(w, h)
    let th = ss * clamp(a0, 0.0, 20000.0) / 1e5 // tooth height
    let leanMax = n == 6 ? 5380.0 : 2730.0
    let l = ss * clamp(a1, 0.0, clamp(a0, 0.0, 20000.0).rustMin(leanMax)) / 1e5 // flank lean
    let (cx, cy) = (w / 2.0, h / 2.0)
    let (rx, ry) = (max(cx - th, 0.0), max(cy - th, 0.0))
    let r = max(ss / 2.0 - th, 1e-9)
    let half = atan((th + l) / 2.0 / r)
    let step = 2.0 * Double.pi / Double(n)
    func onBody(_ t: Double) -> DPoint {
        DPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
    }
    let b = Pb()
    for k in 0..<n {
        let t = -Double.pi / 2.0 + step * Double(k)
        // The tooth stands along the body's normal at its centre.
        let nrm = DVec(dx: cos(t) * ry, dy: sin(t) * rx)
        let u = nrm.hypot > 1e-12 ? nrm / nrm.hypot : DVec(dx: cos(t), dy: sin(t))
        let v = DVec(dx: -u.dy, dy: u.dx)
        let (r0, r1) = (onBody(t - half), onBody(t + half))
        let (c0, c1) = (r0 + u * th + v * l, r1 + u * th - v * l)
        if k == 0 {
            b.m(r0.x, r0.y)
        } else {
            b.arc(rx, ry, (t - step + half).toDegrees, (step - 2.0 * half).toDegrees)
        }
        b.l(c0.x, c0.y).l(c1.x, c1.y).l(r1.x, r1.y)
    }
    let tLast = -Double.pi / 2.0 + step * Double(n - 1)
    b.arc(rx, ry, (tLast + half).toDegrees, (step - 2.0 * half).toDegrees).z()
    let k = 1.0 / 2.0.squareRoot()
    let text = DRect(x0: cx - rx * k, y0: cy - ry * k, x1: cx + rx * k, y1: cy + ry * k)
    return simple(b.takePath(), text)
}

/// Two arrows on a band that steps down in the middle: the left arrow sits high, the right one low,
/// and the band rolls over between them in a shaded half-ellipse curl.
func leftRightRibbon(_ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
    let ss = min(w, h)
    let sh = h * clamp(a2, 0.0, 33333.0) / 1e5 // step between the two halves
    let bt = min(h * max(a0, 0.0) / 1e5, h - sh) // band thickness
    let cx = w / 2.0
    let (rx, ry) = (w / 32.0, min(sh / 4.0, w / 24.0))
    let hb = min(ss * max(a1, 0.0) / 1e5, cx - rx) // head length
    let yc = (h - sh) / 2.0
    let (lt, lb) = (yc - bt / 2.0, yc + bt / 2.0)
    let (rt, rb) = (lt + sh, lb + sh)
    // The left half: filled as a closed outline, stroked only where it can show.
    let edge = Pb()
    edge.m(cx - rx, lb).l(hb, lb).l(hb, h - sh).l(0.0, yc).l(hb, 0.0).l(hb, lt).l(cx, lt)
    edge.arc(rx, ry, 270.0, 180.0).arc(rx, ry, 270.0, -90.0)
    let left = Pb()
    left.m(0.0, yc).l(hb, 0.0).l(hb, lt).l(cx, lt).arc(rx, ry, 270.0, 180.0).arc(rx, ry, 270.0, -180.0)
    left.l(cx, max(lb, lt + 4.0 * ry)).l(hb, lb).l(hb, h - sh).z()
    let curl = Pb()
    curl.m(cx + rx, lt + ry).l(cx + rx, rt).l(cx, lt + 4.0 * ry).arc(rx, ry, 90.0, 180.0).arc(rx, ry, 90.0, -90.0).z()
    let right = Pb()
    right.m(w, yc + sh).l(w - hb, h).l(w - hb, rb).l(cx, rb).arc(rx, ry, 90.0, 90.0).l(cx - rx, rt - ry).arc(rx, ry, 180.0, -90.0)
    right.l(w - hb, rt).l(w - hb, sh).z()
    return Geometry(
        paths: [fillOnly(left.takePath()), strokeOnly(edge.takePath()), shade(curl.takePath(), .darkenLess), fill(right.takePath())],
        textRect: DRect.new(min(hb, cx - rx), rt, max(w - hb, cx + rx), max(lb, rt))
    )
}

/// Adds a piece of the parabola `y = y0 + d·(1 − ((x − w/2)/(w/2))²)` from the current point (at
/// `xa`) to `xb`, as one quadratic curve.
func sag(_ b: Pb, _ w: Double, _ d: Double, _ y0: Double, _ xa: Double, _ xb: Double) {
    let hw = max(w / 2.0, 1e-9)
    func f(_ x: Double) -> Double {
        let q = (x - hw) / hw
        return y0 + d * (1.0 - q * q)
    }
    let slope = -2.0 * d * (xa - hw) / (hw * hw)
    b.q((xa + xb) / 2.0, f(xa) + slope * (xb - xa) / 2.0, xb, f(xb))
}

/// A ribbon whose edges sag along one parabola: a front band in the middle and two notched ends
/// behind it, joined by shaded folds. Built sagging downwards; `up` mirrors it vertically.
func ellipseRibbon(up: Bool, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
    let th = h * clamp(a0, 0.0, 100000.0) / 1e5 // band drop at the centre
    // Sag of every edge: never more than the drop, never so little that the band would rise
    // above the ends by more than half their height.
    let d = clamp(max(h * max(a2, 0.0) / 1e5, th - (h - th) / 2.0), 0.0, th)
    let bw = w * clamp(a1, 25000.0, 75000.0) / 1e5
    let (x0, x1) = ((w - bw) / 2.0, (w + bw) / 2.0)
    let ear = w / 8.0
    let (xf, xg) = (x0 + ear, x1 - ear)
    let e = h - th // band height
    let off = th - d // band top below the ends' top
    func t(_ x: Double) -> Double {
        let hw = max(w / 2.0, 1e-9)
        let q = (x - hw) / hw
        return d * (1.0 - q * q)
    }
    let ends = Pb()
    ends.m(0.0, 0.0)
    sag(ends, w, d, 0.0, 0.0, xf)
    ends.l(xf, t(xf) + off).l(x0, t(x0) + off).l(x0, t(x0) + e)
    sag(ends, w, d, e, x0, 0.0)
    ends.l(ear, t(ear) + e / 2.0).z()
    ends.m(w, 0.0).l(w - ear, t(w - ear) + e / 2.0).l(w, e)
    sag(ends, w, d, e, w, x1)
    ends.l(x1, t(x1) + off).l(xg, t(xg) + off).l(xg, t(xg))
    sag(ends, w, d, 0.0, xg, w)
    ends.z()
    let folds = Pb()
    folds.poly([(x0, t(x0) + off), (xf, t(xf)), (xf, t(xf) + off)])
    folds.poly([(x1, t(x1) + off), (xg, t(xg)), (xg, t(xg) + off)])
    let band = Pb()
    band.m(x0, t(x0) + off)
    sag(band, w, d, off, x0, x1)
    band.l(x1, t(x1) + off + e)
    sag(band, w, d, off + e, x1, x0)
    band.z()
    var paths = [fill(ends.takePath()), shade(folds.takePath(), .darkenLess), fill(band.takePath())]
    var text = DRect.new(x0, th, x1, t(x0) + off + e)
    if up {
        let m = DAffine(a: 1.0, b: 0.0, c: 0.0, d: -1.0, e: 0.0, f: h)
        for i in paths.indices {
            paths[i].path.applyAffine(m)
        }
        text = m.transformRectBBox(text)
    }
    return Geometry(paths: paths, textRect: text)
}

/// A sweeping arrow rising from the bottom-left corner. The band's two edges are quadratic curves
/// from the corner; the head's base leans slightly forward and reaches one eighth of the shorter
/// side above and below the band. The tilt and the tip's lift were fitted to the reference look.
func swoosh(_ w: Double, _ h: Double, _ a0: Double, _ a1: Double) -> Geometry {
    let TILT = 0.1126 // tan of the head base's lean from vertical
    let LIFT = 0.051  // tip height above the band's centre, per unit of height
    let ss = min(w, h)
    let e = ss / 8.0
    let th = min(h * max(a0, 0.0) / 1e5, max(h - 2.0 * e, 0.0))
    // The head is at least long enough to keep its leaning base inside the frame.
    let hl = min(max(ss * max(a1, 0.0) / 1e5, (e + th) * TILT), max(w - e * TILT, 0.0))
    let qx = w - hl
    let b = Pb()
    b.m(0.0, h)
        .q(w / 6.0, h / 3.0, qx, e)
        .l(qx - e * TILT, 0.0)
        .l(w, clamp(e + th / 2.0 - LIFT * h, 0.0, 2.0 * e + th))
        .l(min(qx + (e + th) * TILT, w), 2.0 * e + th)
        .l(min(qx + th * TILT, w), e + th)
        .q(w / 4.0, min(th + h / 12.0 + e, h), 0.0, h)
        .z()
    return simple(b.takePath(), DRect.new(0.0, 0.0, w, h))
}

/// A band that sweeps around half an ellipse and ends in an arrow head. Built pointing right
/// (`curvedRightArrow`) in a `cw`×`ch` frame, then turned for the other directions.
///
/// Both halves of the band hang off one ellipse touching the far side: its centre sits on the
/// head side's edge, its horizontal radius is the full length, and the band has a constant
/// vertical thickness. The back half (shaded) starts flat against the head side; the front half
/// runs to the head, centred on the band where it ends.
func curvedArrow(_ name: String, _ w: Double, _ h: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Geometry {
    let alongX = name == "curvedRightArrow" || name == "curvedLeftArrow"
    let (cw, ch) = alongX ? (w, h) : (h, w)
    let ss = min(cw, ch)
    let head = min(ss * max(a1, 0.0) / 1e5, ch / 2.0)
    let th = min(ss * max(a0, 0.0) / 1e5, head)
    let hl = min(ss * max(a2, 0.0) / 1e5, cw)
    let hh = head / 2.0
    // The band's centre line, carried on to the head side, ends at the tip, which sits half a
    // head width above the bottom.
    let r = max((ch - hh - th / 2.0) / 2.0, 0.0)
    // Parametric angle where the front band reaches the head base.
    let te = cw > 0.0 ? acos(clamp(-(hl / cw), -1.0, 1.0)).toDegrees : 90.0
    let back = Pb()
    back.m(cw, 0.0).arc(cw, r, 270.0, -90.0).l(0.0, r + th).arc(cw, r, 180.0, 90.0).z()
    let front = Pb()
    front.m(0.0, r).arc(cw, r, 180.0, te - 180.0)
    let yb = front.cur.y
    let yc = yb + th / 2.0
    front.l(cw - hl, yc - hh).l(cw, 2.0 * r + th / 2.0).l(cw - hl, yc + hh).l(cw - hl, yb + th).arc(cw, r, te, 180.0 - te).z()
    let m: DAffine
    switch name {
    case "curvedLeftArrow": m = DAffine(a: -1.0, b: 0.0, c: 0.0, d: 1.0, e: w, f: 0.0)
    case "curvedUpArrow": m = DAffine(a: 0.0, b: -1.0, c: 1.0, d: 0.0, e: 0.0, f: h)
    case "curvedDownArrow": m = DAffine(a: 0.0, b: 1.0, c: 1.0, d: 0.0, e: 0.0, f: 0.0)
    default: m = .identity
    }
    var backPath = back.takePath()
    var frontPath = front.takePath()
    backPath.applyAffine(m)
    frontPath.applyAffine(m)
    return Geometry(
        paths: [shade(backPath, .darkenLess), fill(frontPath)],
        textRect: DRect.new(0.0, 0.0, w, h)
    )
}

/// A rectangle with a callout leader through `pts` points (`(y, x)` adjust pairs in 1/100 000 of
/// the height and width), optionally with an accent bar at the first point's x and a border.
func lineCallout(_ w: Double, _ h: Double, _ a: (Int) -> Double, _ pts: Int, _ accent: Bool, _ border: Bool) -> Geometry {
    let body = cornerRect(w, h, [.square, .square, .square, .square])
    // Leaders may reach well outside the box, but not without bound.
    func pt(_ i: Int) -> (Double, Double) {
        (w * clamp(a(2 * i + 1), -1e7, 1e7) / 1e5, h * clamp(a(2 * i), -1e7, 1e7) / 1e5)
    }
    let l = Pb()
    let (x0, y0) = pt(0)
    l.m(x0, y0)
    for i in 1..<pts {
        let (x, y) = pt(i)
        l.l(x, y)
    }
    var paths = [border ? fill(body) : fillOnly(body)]
    if accent {
        paths.append(strokeOnly(Pb().m(x0, 0.0).l(x0, h).takePath()))
    }
    paths.append(strokeOnly(l.takePath()))
    return Geometry(paths: paths, textRect: DRect.new(0.0, 0.0, w, h))
}
