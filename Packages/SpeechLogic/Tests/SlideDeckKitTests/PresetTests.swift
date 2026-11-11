// Tests for the preset geometry port (Geom/PresetCatalog/PresetShapes/
// PresetShapesExtra). Ported from the geometry-shape tests in DeckCraft's
// preset.rs and preset/extra.rs @ a0eeb34 — the handle-dragging tests are
// editor-only and not ported. Point checks measure reference-outline points
// (read off PowerPoint renders in DeckCraft's originals), distances computed
// over a finely flattened outline.

import XCTest
@testable import SlideDeckKit

final class PresetTests: XCTestCase {

    // MARK: - helpers

    private func outline(_ name: String, _ w: Double, _ h: Double, _ adj: [Double]) -> GeomPath {
        presetBuild(name, w, h, adj)?.outline() ?? GeomPath()
    }

    /// Distance from `p` to the nearest point of the (flattened) outline.
    private func dist(_ path: GeomPath, _ p: DPoint) -> Double {
        var best = Double.greatestFiniteMagnitude
        for el in path.flattened(tolerance: 0.0001) {
            let (a, b): (DPoint, DPoint)
            switch el {
            case .move: continue
            case .line(let a0, let b0): (a, b) = (a0, b0)
            case .close(let last, let start): (a, b) = (last, start)
            }
            let d = b - a
            let len2 = d.hypot2
            let t = len2 > 0.0 ? clamp((p - a).dot(d) / len2, 0.0, 1.0) : 0.0
            best = min(best, (a + d * t - p).hypot)
        }
        return best
    }

    /// Distance from `p` to the nearest point of ANY sub-path (the Rust tests'
    /// `on_path` semantics — e.g. the disk's top ellipse is `paths[1]`).
    private func dist(_ g: Geometry, _ p: DPoint) -> Double {
        g.paths.map { dist($0.path, p) }.min() ?? Double.greatestFiniteMagnitude
    }

    /// Asserts every point lies within 1pt of the outline.
    private func on(_ name: String, _ w: Double, _ h: Double, _ adj: [Double], _ pts: [(Double, Double)],
                    file: StaticString = #filePath, line: UInt = #line) {
        let path = outline(name, w, h, adj)
        for (x, y) in pts {
            let d = dist(path, DPoint(x: x, y: y))
            XCTAssertTrue(d < 1.0, "\(name) \(w)x\(h) \(adj): (\(x), \(y)) is \(String(format: "%.2f", d)) from the outline", file: file, line: line)
        }
    }

    // MARK: - bounds and robustness (preset.rs)

    func testEveryCatalogPresetBuildsWithinBounds() {
        for p in CATALOG {
            for (w, h) in [(200.0, 100.0), (100.0, 200.0), (50.0, 50.0), (0.0, 0.0), (1.0, 300.0)] {
                let g = presetBuild(p.name, w, h, [])
                XCTAssertNotNil(g, "\(p.name) did not build")
                guard let g else { continue }
                XCTAssertFalse(g.paths.isEmpty, "\(p.name) has no paths")
                for s in g.paths {
                    let bb = s.path.boundingBox()
                    if w > 0.0 && h > 0.0 && !p.name.contains("Connector") && !p.name.contains("allout") {
                        let tol = max(w, h) * 0.35 + 1.0
                        XCTAssertTrue(bb.x0 >= -tol && bb.y0 >= -tol && bb.x1 <= w + tol && bb.y1 <= h + tol,
                                      "\(p.name) \(w)x\(h) out of bounds: \(bb)")
                    }
                    XCTAssertTrue(bb.x0.isFinite && bb.y1.isFinite, "\(p.name) produced non-finite geometry")
                }
                XCTAssertTrue(g.textRect.x0.isFinite && g.textRect.y1.isFinite, p.name)
            }
        }
    }

    func testHostileAdjustValuesNeverPanic() {
        for p in CATALOG {
            for v in [Double.nan, Double.infinity, -1e12, 1e12, -1.0, 0.0] {
                let adj = [Double](repeating: v, count: 6)
                let g = presetBuild(p.name, 120.0, 80.0, adj)
                XCTAssertNotNil(g, p.name)
            }
        }
        XCTAssertNil(presetBuild("rect", Double.nan, 10.0, []))
        XCTAssertNil(presetBuild("noSuchShape", 10.0, 10.0, []))
    }

    func testCatalogNamesAreUnique() {
        let names = CATALOG.map { $0.name }
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertGreaterThanOrEqual(names.count, 140)
    }

    func testRectAreaAndEllipseArea() {
        let g = presetBuild("rect", 100.0, 50.0, [])!
        XCTAssertEqual(abs(g.paths[0].path.area()), 5000.0, accuracy: 1e-6)
        let e = presetBuild("ellipse", 100.0, 50.0, [])!
        let expect = Double.pi * 50.0 * 25.0
        XCTAssertLessThan(abs(e.paths[0].path.area() - expect) / expect, 0.01)
    }

    func testLinesAreOpen() {
        XCTAssertTrue(presetBuild("line", 10.0, 10.0, [])!.isOpen)
        XCTAssertFalse(presetBuild("rect", 10.0, 10.0, [])!.isOpen)
    }

    // MARK: - the standard's own coordinates (preset.rs)

    func testFixedShapesFollowTheStandardsCoordinates() {
        // Points of ECMA-376's definitions (in 21600ths), checked on a 216 × 108 box.
        let (w, h) = (216.0, 108.0)
        func at(_ x: Double, _ y: Double) -> DPoint { DPoint(x: w * x / 21600.0, y: h * y / 21600.0) }
        var g = presetBuild("lightningBolt", w, h, [])!
        for (x, y) in [(8472.0, 0.0), (16577.0, 12007.0), (21600.0, 21600.0), (0.0, 3890.0)] {
            XCTAssertLessThan(dist(g, at(x, y)), 1e-6, "lightningBolt (\(x), \(y))")
        }
        g = presetBuild("irregularSeal1", w, h, [])!
        XCTAssertLessThan(dist(g, at(14522.0, 0.0)), 1e-6)
        XCTAssertLessThan(dist(g, at(8485.0, 21600.0)), 1e-6)
        g = presetBuild("irregularSeal2", w, h, [])!
        XCTAssertLessThan(dist(g, at(14790.0, 0.0)), 1e-6)
        XCTAssertLessThan(dist(g, at(4917.0, 21600.0)), 1e-6)
        // The heart's point is the middle of the bottom edge, its notch a quarter down.
        g = presetBuild("heart", w, h, [])!
        XCTAssertLessThan(dist(g, DPoint(x: w / 2.0, y: h)), 1e-6)
        XCTAssertLessThan(dist(g, DPoint(x: w / 2.0, y: h / 4.0)), 1e-6)
        g = presetBuild("flowChartDocument", w, h, [])!
        XCTAssertLessThan(dist(g, at(21600.0, 17322.0)), 1e-6)
        XCTAssertLessThan(dist(g, at(0.0, 20172.0)), 1e-6)
        // Punched tape: the top edge dips to a fifth of the height a quarter of the way along.
        g = presetBuild("flowChartPunchedTape", w, h, [])!
        XCTAssertLessThan(dist(g, DPoint(x: w / 4.0, y: h / 5.0)), 1e-3)
        XCTAssertLessThan(dist(g, DPoint(x: w * 0.75, y: 0.0)), 1e-3)
        g = presetBuild("flowChartMultidocument", w, h, [])!
        XCTAssertLessThan(dist(g, at(2972.0, 0.0)), 1e-6)
        XCTAssertLessThan(dist(g, at(18595.0, 18022.0)), 1e-6)
    }

    func testEquationShapesMatchPowerPointsOutlines() {
        // Corners read off PowerPoint's own outlines of the presets at their default adjusts.
        var g = presetBuild("mathMultiply", 216.0, 216.0, [])!
        for (x, y) in [(0.32333, 0.15702), (0.5, 0.33369), (0.84298, 0.32333), (0.66631, 0.5), (0.33369, 0.5)] {
            XCTAssertLessThan(dist(g, DPoint(x: 216.0 * x, y: 216.0 * y)), 0.01, "multiply (\(x), \(y))")
        }
        g = presetBuild("mathEqual", 300.0, 120.0, [])!
        for (x, y) in [(0.13255, 0.5588), (0.86745, 0.794), (0.13255, 0.206), (0.86745, 0.4412)] {
            XCTAssertLessThan(dist(g, DPoint(x: 300.0 * x, y: 120.0 * y)), 0.01, "equal (\(x), \(y))")
        }
        g = presetBuild("mathPlus", 216.0, 216.0, [])!
        XCTAssertLessThan(dist(g, DPoint(x: 216.0 * 0.3824, y: 216.0 * 0.13255)), 0.01)
        XCTAssertLessThan(dist(g, DPoint(x: 216.0 * 0.86745, y: 216.0 * 0.6176)), 0.01)
        // A tall "not equal": its slash, leaning at the default 110° from top to bottom, reaches
        // past the box's sides exactly as far as PowerPoint's (-22.242 to 122.242).
        g = presetBuild("mathNotEqual", 100.0, 260.0, [])!
        let bb = g.paths[0].path.boundingBox()
        XCTAssertEqual(bb.x0, -22.242, accuracy: 0.01)
        XCTAssertEqual(bb.x1, 122.242, accuracy: 0.01)
        XCTAssertEqual(bb.y0, 0.0, accuracy: 1e-6)
        XCTAssertEqual(bb.y1, 260.0, accuracy: 1e-6)
    }

    func testSunAndWavesMatchPowerPointsOutlines() {
        // Points read off PowerPoint's outlines of the presets (216 pt square, default adjusts).
        let k = 216.0
        var g = presetBuild("sun", k, k, [])!
        for (x, y) in [(0.85352, 0.14644), (0.76161, 0.33987), (0.66013, 0.23839), (0.42825, 0.79823),
                       (0.20177, 0.57175), (0.75, 0.5), (0.5, 0.25)] {
            XCTAssertLessThan(dist(g, DPoint(x: k * x, y: k * y)), 0.02, "sun (\(x), \(y))")
        }
        g = presetBuild("wave", k, k, [])!
        for (x, y) in [(0.21875, 0.00484), (1.0, 0.125), (1.0, 0.875), (0.0, 0.875)] {
            XCTAssertLessThan(dist(g, DPoint(x: k * x, y: k * y)), 0.05, "wave (\(x), \(y))")
        }
        // Shifted: a wave of 300 × 120 with adj (20000, 8000) starts 0.16 of the width in.
        g = presetBuild("wave", 300.0, 120.0, [20000.0, 8000.0])!
        for (x, y) in [(0.18375, 0.00774), (0.84, 0.2), (1.0, 0.8), (0.16, 0.8)] {
            XCTAssertLessThan(dist(g, DPoint(x: 300.0 * x, y: 120.0 * y)), 0.05, "shifted wave (\(x), \(y))")
        }
    }

    func testStarTextRectanglesFollowTheStandard() {
        // star5 at its default 19098 in a 144 pt square: the inner pentagon, about 0.38 of the
        // width, from y ≈ 55 to ≈ 110.
        var g = presetBuild("star5", 144.0, 144.0, [])!
        var t = g.textRect
        XCTAssertEqual(t.width, 55.0, accuracy: 1.0)
        XCTAssertEqual(t.y0, 55.0, accuracy: 1.0)
        XCTAssertEqual(t.y1, 110.0, accuracy: 1.0)
        // star4 at 12500: the square through its inner points' 45° corners.
        g = presetBuild("star4", 144.0, 144.0, [])!
        t = g.textRect
        XCTAssertEqual(t.width, 72.0 * 0.25 * 2.0.squareRoot(), accuracy: 0.5)
    }

    func testStarsAreStretchedLikeTheStandards() {
        // star5 in a 216 pt square: top point at the top middle, side points at 18 degrees on an
        // ellipse 5.146% wider and 10.557% taller, centred 10.557% below the middle; its bottom
        // points reach the box's bottom edge.
        let k = 216.0
        var g = presetBuild("star5", k, k, [])!
        let (rx, ry, cy) = (k / 2.0 * 1.05146, k / 2.0 * 1.10557, k / 2.0 * 1.10557)
        let a = (18.0).toRadians
        XCTAssertLessThan(dist(g, DPoint(x: k / 2.0, y: 0.0)), 1e-6)
        XCTAssertLessThan(dist(g, DPoint(x: k / 2.0 + rx * cos(a), y: cy - ry * sin(a))), 1e-6)
        var bb = g.paths[0].path.boundingBox()
        XCTAssertEqual(bb.x0, 0.0, accuracy: 0.5)
        XCTAssertEqual(bb.x1, k, accuracy: 0.5)
        XCTAssertEqual(bb.y1, k, accuracy: 0.5)
        // star6 is 15.47% wider than its box's half-width allows (its points touch the sides).
        g = presetBuild("star6", k, k, [])!
        bb = g.paths[0].path.boundingBox()
        XCTAssertEqual(bb.x0, 0.0, accuracy: 0.5)
        XCTAssertEqual(bb.x1, k, accuracy: 0.5)
    }

    func testMoonDiskAndDrumMatchPowerPointsOutlines() {
        let k = 216.0
        // Moon, default: the inner edge runs through (0.5, 0.5) and (0.625, 0.2266) of the box.
        var g = presetBuild("moon", k, k, [])!
        for (x, y) in [(0.5, 0.5), (0.626, 0.2266), (0.0, 0.5), (1.0, 0.0)] {
            XCTAssertLessThan(dist(g, DPoint(x: k * x, y: k * y)), 0.5, "moon (\(x), \(y))")
        }
        // 300 × 120 at 30%: its inner edge reaches 30% of the width in.
        g = presetBuild("moon", 300.0, 120.0, [30000.0])!
        XCTAssertLessThan(dist(g, DPoint(x: 90.0, y: 60.0)), 0.5)
        // Magnetic disk ends are ellipses h/6 high, drum ends w/6 across.
        g = presetBuild("flowChartMagneticDisk", k, k, [])!
        XCTAssertLessThan(dist(g, DPoint(x: k, y: k / 6.0)), 0.01)
        XCTAssertLessThan(dist(g, DPoint(x: k / 2.0, y: k / 3.0)), 0.5)
        g = presetBuild("flowChartMagneticDrum", k, k, [])!
        XCTAssertLessThan(dist(g, DPoint(x: k / 6.0, y: 0.0)), 0.01)
        XCTAssertLessThan(dist(g, DPoint(x: 0.0, y: k / 2.0)), 0.01)
    }

    func testCloudFillsItsBoxAtAnyAspectAndHasCreases() {
        for (w, h) in [(200.0, 200.0), (300.0, 100.0), (60.0, 180.0)] {
            let g = presetBuild("cloud", w, h, [])!
            let bb = g.paths[0].path.boundingBox()
            XCTAssertLessThan(abs(bb.x0), w * 0.02, "\(w)×\(h)")
            XCTAssertLessThan(abs(bb.x1 - w), w * 0.02)
            XCTAssertLessThan(abs(bb.y0), h * 0.02)
            XCTAssertLessThan(abs(bb.y1 - h), h * 0.02)
            XCTAssertEqual(g.paths.count, 2, "outline and creases")
            XCTAssertTrue(g.paths[1].stroke)
            XCTAssertEqual(g.paths[1].fill, .none)
        }
    }

    func testBracketsAndBracesFillOutToTheirStraightSide() {
        // PowerPoint fills a bracket or brace (when it has a fill) between its curve and the
        // straight side it opens to; only the curve is outlined.
        for name in ["leftBracket", "rightBracket", "leftBrace", "rightBrace"] {
            let g = presetBuild(name, 40.0, 100.0, [])!
            let filled = g.paths.filter { $0.fill != .none }
            XCTAssertEqual(filled.count, 1, name)
            XCTAssertFalse(filled[0].stroke, "\(name): the filled area is not outlined")
            let area = abs(filled[0].path.area())
            XCTAssertGreaterThan(area, 40.0 * 100.0 * 0.4, "\(name): \(area)")
            XCTAssertLessThan(area, 40.0 * 100.0, "\(name): \(area)")
            XCTAssertTrue(g.paths.contains { $0.stroke && $0.fill == .none }, "\(name): the curve is outlined")
        }
    }

    // MARK: - the arc builder

    func testSpecArcsTakeAnglesAsDirectionsFromTheCentre() {
        // A DrawingML arc of a 2:1 ellipse from 45° to 90°: 45° is the direction (1, 1) from the
        // centre, which on that ellipse is the point (r/√5)·(2, 1)… scaled so it lies on it.
        let b = Pb()
        b.m(0.0, 0.0).arcSpec(200.0, 100.0, 45.0, 45.0)
        let p = b.takePath()
        guard case .cubic(_, _, let q)? = p.elements.last else {
            XCTFail("expected a cubic as the last element")
            return
        }
        // Centre: the start sits at direction 45°, i.e. at (k, k) from it with (k/200)² + (k/100)² = 1.
        let k = 1.0 / (1.0 / 40000.0 + 1.0 / 10000.0).squareRoot()
        let c = DPoint(x: -k, y: -k)
        XCTAssertEqual(q.x, c.x, accuracy: 1e-6)
        XCTAssertEqual(q.y, c.y + 100.0, accuracy: 1e-6)
    }

    // MARK: - extra.rs presets

    private let extraNames = [
        "lineInv", "nonIsoscelesTrapezoid", "pieWedge", "leftRightArrowCallout", "upDownArrowCallout",
        "quadArrowCallout", "circularArrow", "leftCircularArrow", "leftRightCircularArrow",
        "curvedRightArrow", "curvedLeftArrow", "curvedUpArrow", "curvedDownArrow", "swooshArrow",
        "callout1", "callout2", "callout3", "accentCallout1", "accentCallout2", "accentCallout3",
        "borderCallout2", "borderCallout3", "accentBorderCallout1", "accentBorderCallout2", "accentBorderCallout3",
        "ellipseRibbon", "ellipseRibbon2", "leftRightRibbon", "flowChartOfflineStorage", "gear6",
        "gear9", "funnel", "cornerTabs", "squareTabs", "plaqueTabs", "chartX", "chartStar", "chartPlus",
    ]

    func testNewPresetsAreInTheCatalog() {
        for n in extraNames {
            let i = presetInfo(n)
            XCTAssertNotNil(i, "\(n) missing from the catalog")
            XCTAssertFalse(i?.label.isEmpty ?? true)
        }
        XCTAssertGreaterThanOrEqual(CATALOG.count, 183)
    }

    func testNewPresetsBuildWithinBoundsAtManySizesAndAdjusts() {
        let sizes = [(480.0, 300.0), (300.0, 300.0), (200.0, 460.0), (100.0, 460.0), (1.0, 1.0), (0.0, 0.0), (0.0, 50.0), (60.0, 0.0)]
        let maxV = Double.greatestFiniteMagnitude
        let adjusts: [[Double]] = [
            [],
            [Double](repeating: 0.0, count: 8),
            [Double](repeating: 100000.0, count: 8),
            [Double](repeating: -50000.0, count: 8),
            [Double](repeating: 1e12, count: 8),
            [maxV, -maxV, maxV, -maxV, maxV, -maxV, maxV, -maxV],
            [Double.nan, Double.infinity, -Double.infinity, Double.nan, 5.0, 6.0, 7.0, 8.0],
            [30000.0, 60000.0, 20000.0, 9000000.0, 20000.0, 40000.0, 120000.0, -30000.0],
        ]
        for n in extraNames {
            // Line callouts' leaders may reach anywhere, by design.
            let callout = n.contains("allout") && !n.contains("Arrow")
            for (w, h) in sizes {
                for adj in adjusts {
                    let g = presetBuild(n, w, h, adj)
                    XCTAssertNotNil(g, "\(n) did not build")
                    guard let g else { continue }
                    XCTAssertFalse(g.paths.isEmpty, "\(n) has no paths")
                    for s in g.paths {
                        let bb = s.path.boundingBox()
                        XCTAssertTrue(bb.x0.isFinite && bb.y0.isFinite && bb.x1.isFinite && bb.y1.isFinite,
                                      "\(n) \(w)x\(h) \(adj): \(bb)")
                        if !callout {
                            // Circular arrows with a head longer than their ring can hold carry the
                            // inner edge on from the head, as the reference does, so may spill.
                            let spill = n.contains("ircular") ? 0.5 : 0.01
                            let tol = 0.5 + max(w, h) * spill
                            XCTAssertTrue(bb.x0 >= -tol && bb.y0 >= -tol && bb.x1 <= w + tol && bb.y1 <= h + tol,
                                          "\(n) \(w)x\(h) \(adj) out of bounds: \(bb)")
                        }
                    }
                    let t = g.textRect
                    XCTAssertTrue(t.x0.isFinite && t.y0.isFinite && t.x1.isFinite && t.y1.isFinite, "\(n) text rect \(t)")
                }
            }
            let g = presetBuild(n, 480.0, 300.0, [])
            XCTAssertNotNil(g, n)
            XCTAssertGreaterThanOrEqual(g?.outline().elements.count ?? 0, 2, "\(n) default outline is empty")
        }
    }

    func testSimpleNewPresetsMatchReferencePoints() {
        on("lineInv", 480.0, 300.0, [], [(0.0, 300.0), (480.0, 0.0)])
        on("nonIsoscelesTrapezoid", 480.0, 300.0, [], [(75.0, 0.0), (405.0, 0.0), (0.0, 300.0)])
        on("nonIsoscelesTrapezoid", 200.0, 460.0, [80000.0, 20000.0], [(100.0, 0.0), (160.0, 0.0)])
        on("pieWedge", 480.0, 300.0, [], [(64.3, 150.0), (0.0, 300.0), (480.0, 0.0)])
        on("flowChartOfflineStorage", 480.0, 300.0, [], [(240.0, 300.0), (192.0, 240.0), (288.0, 240.0)])
        on("squareTabs", 480.0, 300.0, [], [(28.3, 28.3), (451.7, 271.7)])
        on("cornerTabs", 480.0, 300.0, [], [(23.3, 5.0)])
        on("plaqueTabs", 480.0, 300.0, [], [(27.85, 5.0)])
        on("chartStar", 480.0, 300.0, [], [(240.0, 0.0), (240.0, 300.0), (48.0, 30.0)])
        on("chartPlus", 480.0, 300.0, [], [(0.0, 150.0), (240.0, 0.0)])
        // Chart markers and plain callouts leave the box unstroked.
        for n in ["chartX", "callout1", "accentCallout2"] {
            let g = presetBuild(n, 100.0, 100.0, [])
            XCTAssertFalse(g?.paths[0].stroke ?? true, n)
        }
    }

    func testLineCalloutsFollowTheirAdjusts() {
        on("callout3", 480.0, 300.0, [], [(-40.0, 56.25), (-80.0, 56.25), (-80.0, 300.0), (-40.0, 338.9)])
        let adj = [50000.0, 110000.0, 20000.0, 120000.0, -20000.0, 80000.0, 30000.0, 40000.0]
        let g = presetBuild("accentBorderCallout3", 480.0, 300.0, adj)
        XCTAssertNotNil(g)
        XCTAssertEqual(g?.paths.count ?? 0, 3)
        XCTAssertTrue(g?.paths[0].stroke ?? false)
        let accent = g!.paths[1].path.boundingBox()
        XCTAssertEqual(accent.x0, 528.0, accuracy: 1e-6)
        XCTAssertEqual(accent.y0, 0.0)
        XCTAssertEqual(accent.y1, 300.0)
        on("accentBorderCallout3", 480.0, 300.0, adj, [(576.0, 60.0), (384.0, -60.0), (192.0, 90.0)])
    }

    func testArrowCalloutsMatchReferencePoints() {
        on("leftRightArrowCallout", 480.0, 300.0, [], [(0.0, 150.0), (75.0, 75.0), (124.5, 0.0), (355.5, 300.0), (480.0, 150.0)])
        on("leftRightArrowCallout", 200.0, 460.0, [], [(50.0, 180.0), (52.0, 0.0), (148.0, 460.0)])
        on("upDownArrowCallout", 480.0, 300.0, [], [(240.0, 0.0), (0.0, 77.8), (480.0, 222.2), (240.0, 300.0)])
        on("quadArrowCallout", 480.0, 300.0, [], [(0.0, 150.0), (124.5, 77.8), (240.0, 0.0), (480.0, 150.0), (240.0, 300.0)])
    }

    func testCurvedArrowsMatchReferencePoints() {
        on("curvedRightArrow", 480.0, 300.0, [], [
            (480.0, 0.0), (480.0, 75.0), (480.0, 225.0), (405.0, 149.0), (405.0, 299.0), (100.0, 151.5), (300.0, 6.7),
        ])
        on("curvedRightArrow", 200.0, 460.0, [30000.0, 60000.0, 40000.0], [(200.0, 400.0), (120.0, 324.5), (120.0, 443.5), (200.0, 60.0)])
        // The band never outgrows the head; the head never outgrows half the frame.
        on("curvedRightArrow", 200.0, 460.0, [60000.0, 30000.0, 80000.0], [(200.0, 60.0)])
        on("curvedLeftArrow", 480.0, 300.0, [], [(0.0, 225.0), (0.0, 0.0)])
        on("curvedUpArrow", 480.0, 300.0, [], [(405.0, 0.0), (0.0, 0.0), (75.0, 0.0)])
        on("curvedDownArrow", 480.0, 300.0, [], [(405.0, 300.0), (0.0, 300.0)])
        let g = presetBuild("curvedRightArrow", 480.0, 300.0, [])
        XCTAssertEqual(g?.paths[0].fill ?? .norm, .darkenLess)
    }

    func testSwooshMatchesReferencePoints() {
        on("swooshArrow", 480.0, 300.0, [], [(0.0, 300.0), (425.8, 0.0), (480.0, 59.7), (442.8, 150.0), (202.0, 105.5), (202.0, 159.0)])
        on("swooshArrow", 480.0, 300.0, [40000.0, 16667.0], [(480.0, 82.2), (447.8, 195.0)])
        on("swooshArrow", 200.0, 460.0, [], [(163.9, 0.0), (200.0, 59.4)])
    }

    func testRibbonsMatchReferencePoints() {
        on("ellipseRibbon", 480.0, 300.0, [], [
            (0.0, 0.0), (120.0, 28.1), (60.0, 128.9), (240.0, 300.0), (120.0, 66.1), (180.0, 72.2), (180.0, 35.2),
        ])
        on("ellipseRibbon", 480.0, 300.0, [30000.0, 60000.0, 20000.0], [(120.0, 45.0), (240.0, 300.0), (96.0, 68.4)])
        on("ellipseRibbon", 480.0, 300.0, [80000.0, 20000.0, 60000.0], [(240.0, 240.0), (1.0, 61.75)])
        on("ellipseRibbon2", 480.0, 300.0, [], [(0.0, 300.0), (240.0, 0.0)])
        on("leftRightRibbon", 480.0, 300.0, [], [
            (0.0, 125.0), (150.0, 0.0), (150.0, 50.0), (255.0, 62.5), (225.0, 87.5), (480.0, 175.0), (330.0, 300.0),
        ])
        on("leftRightRibbon", 480.0, 300.0, [90000.0, 10000.0, 60000.0], [(0.0, 100.0), (480.0, 200.0), (240.0, 300.0)])
    }

    func testGearsAndFunnelMatchReferencePoints() {
        // Square gear6: body radius 105, top tooth tip 3.5 inside the frame, tip half-width ~16.3.
        on("gear6", 300.0, 300.0, [], [(150.0, 3.5), (133.7, 3.5), (166.3, 3.5), (45.0, 150.0)])
        on("gear9", 300.0, 300.0, [], [(150.0, 1.0), (30.0, 150.0)])
        on("gear6", 480.0, 300.0, [], [(240.0, 3.5), (201.0, 3.5)])
        on("funnel", 480.0, 300.0, [], [(240.0, 0.0), (0.0, 75.0), (240.0, 15.0), (15.0, 75.0), (240.0, 300.0), (60.5, 150.0)])
        let g = presetBuild("funnel", 480.0, 300.0, [])
        XCTAssertTrue(g?.paths[0].evenOdd ?? false)
    }

    func testCircularArrowsMatchReferencePoints() {
        on("circularArrow", 300.0, 300.0, [], [
            (19.0, 150.0), (56.5, 150.0), (150.0, 19.0), (262.4, 150.0), (218.6, 113.4), (293.6, 113.4),
        ])
        on("circularArrow", 300.0, 300.0, [20000.0, 1800000.0, 18000000.0, 5400000.0, 20000.0], [
            (150.0, 270.0), (150.0, 210.0), (247.0, 42.1), (143.0, 102.1), (227.9, 105.0),
        ])
        on("leftCircularArrow", 300.0, 300.0, [], [(37.6, 150.0), (262.4, 150.0), (150.0, 281.0)])
        on("leftRightCircularArrow", 300.0, 300.0, [], [(262.4, 150.0), (37.6, 150.0), (150.0, 19.0)])
        // The band never grows past twice the head's half-width.
        on("circularArrow", 300.0, 300.0, [25000.0, 1142319.0, 20457681.0, 10800000.0, 5000.0], [(0.0, 150.0), (30.0, 150.0)])
    }

    // MARK: - Geom basics (geom lib.rs tests)

    func testEmuRoundtripIsExact() {
        for emu: Int64 in [0, 1, 12_699, 12_700, 914_400, 12_192_000, 6_858_000, -5, 123_456_789] {
            XCTAssertEqual(ptToEmu(emuToPt(emu)), emu)
        }
        XCTAssertEqual(ptToEmu(Double.nan), 0)
        XCTAssertEqual(ptToEmu(Double.infinity), 0)
    }

    func testXfrmAffineRotationAboutCenter() {
        let x = Xfrm(x: 10.0, y: 20.0, w: 100.0, h: 50.0, rot: 90.0)
        let c = x.affine().apply(DPoint(x: 50.0, y: 25.0))
        XCTAssertEqual(c.x, 60.0, accuracy: 1e-9)
        XCTAssertEqual(c.y, 45.0, accuracy: 1e-9)
        let b = x.bounds()
        XCTAssertEqual(b.width, 50.0, accuracy: 1e-9)
        XCTAssertEqual(b.height, 100.0, accuracy: 1e-9)
    }

    func testFlipsMirrorLocalSpace() {
        let x = Xfrm(x: 0.0, y: 0.0, w: 100.0, h: 50.0, flipH: true)
        let p = x.affine().apply(DPoint(x: 0.0, y: 0.0))
        XCTAssertEqual(p.x, 100.0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.0, accuracy: 1e-9)
    }

    func testGroupChildMapping() {
        let gfrm = Xfrm(x: 100.0, y: 100.0, w: 200.0, h: 100.0)
        let a = groupChildAffine(group: gfrm, ch: DRect(x0: 0.0, y0: 0.0, x1: 100.0, y1: 50.0))
        let p = a.apply(DPoint(x: 100.0, y: 50.0))
        XCTAssertEqual(p.x, 300.0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 200.0, accuracy: 1e-9)
    }

    func testSVGNumberFormattingMatchesRustDisplay() {
        XCTAssertEqual(svgNum(1.0), "1")
        XCTAssertEqual(svgNum(0.5), "0.5")
        XCTAssertEqual(svgNum(-0.0), "-0")
        XCTAssertEqual(svgNum(100.0), "100")
        XCTAssertEqual(svgNum(1e21), "1000000000000000000000")
        XCTAssertEqual(svgNum(1.5e-7), "0.00000015")
        XCTAssertEqual(svgNum(29.29), "29.29")
    }

    func testToSVGFormat() {
        var p = GeomPath()
        p.move(DPoint(x: 0, y: 0))
        p.line(DPoint(x: 10, y: 20))
        p.cubic(DPoint(x: 1, y: 2), DPoint(x: 3, y: 4), DPoint(x: 5, y: 6))
        p.quad(DPoint(x: 7, y: 8), DPoint(x: 9, y: 10))
        p.close()
        XCTAssertEqual(p.toSVG(), "M0,0 L10,20 C1,2 3,4 5,6 Q7,8 9,10 Z")
    }
}
