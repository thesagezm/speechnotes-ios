// Tests for XML.swift (the bounded DOM over the hand-rolled quick-xml-style
// scanner) and Color.swift. The XML cases pin the semantics the deck readers
// rely on exactly: the §2.11 CR distinction, attribute-value normalization,
// local-name attribute lookup rules, the bounds behaviour and truncation
// folding. Everything here parses bytes built in code — no fixtures.

import XCTest
@testable import SlideDeckKit

final class XMLColorTests: XCTestCase {

    // MARK: - XML basics

    func testParseNestedElementsAndAttrs() throws {
        let doc = try parseXML(Array("<p:sp><a:off x=\"10\" y=\"20\"/><a:t>hi</a:t></p:sp>".utf8))
        XCTAssertEqual(doc.root.name, "p:sp")
        XCTAssertEqual(doc.root.local, "sp")
        XCTAssertEqual(doc.root.prefix, "p")
        XCTAssertEqual(doc.root.children.count, 2)
        let off = doc.root.child("off")!
        XCTAssertEqual(off.attr("x"), "10")
        XCTAssertEqual(off.attr("y"), "20")
        XCTAssertEqual(doc.root.child("t")?.text(), "hi")
    }

    func testNamespacesOnRoot() throws {
        let doc = try parseXML(Array("<r xmlns=\"urn:a\" xmlns:p=\"urn:b\"><p:x/></r>".utf8))
        XCTAssertEqual(doc.nsDecls.count, 2)
        XCTAssertEqual(doc.nsDecls[0].0, "xmlns")
        XCTAssertEqual(doc.nsDecls[1].1, "urn:b")
    }

    func testEntityReferences() throws {
        let doc = try parseXML(Array("<t>a&amp;b&lt;c&gt;d&quot;e&apos;f&#65;&#x41;</t>".utf8))
        XCTAssertEqual(doc.root.text(), "a&b<c>d\"e'fAA")
    }

    func testLiteralCRReadsAsLFButCharRefStaysCR() throws {
        // XML 1.0 §2.11: literal CR LF / lone CR → LF; a `&#13;` reference is
        // not literal and stays a CR. This is why the scanner is hand-rolled.
        let doc = try parseXML(Array("<t>a&#13;b\rc\r\nd</t>".utf8))
        XCTAssertEqual(doc.root.text(), "a\rb\nc\nd")
    }

    func testAttributeNormalization() throws {
        // Literal tab/LF/CR in attribute values normalize to space; references
        // resolve to the real character.
        let doc = try parseXML(Array("<t a=\"x&#9;y\" b=\"p\nq&#10;r\"/>".utf8))
        XCTAssertEqual(doc.root.attr("a"), "x\ty")
        XCTAssertEqual(doc.root.attr("b"), "p q\nr", "a &#10; reference stays a real LF")
    }

    func testBareAmpersandIsLenientText() throws {
        let doc = try parseXML(Array("<t>a & b &amp; c</t>".utf8))
        XCTAssertEqual(doc.root.text(), "a & b & c")
    }

    func testUnknownEntityDropsToEmpty() throws {
        let doc = try parseXML(Array("<t>a&nope;b</t>".utf8))
        XCTAssertEqual(doc.root.text(), "ab")
    }

    func testCDataContent() throws {
        let doc = try parseXML(Array("<t><![CDATA[a<b & c]]></t>".utf8))
        XCTAssertEqual(doc.root.text(), "a<b & c")
    }

    func testCommentsPIsAndDocTypeAreSkipped() throws {
        let raw = "<!--lead--><?pi x?><!DOCTYPE r [<!ENTITY e 'v'>]><t><!--mid-->ok</t><!--tail-->"
        let doc = try parseXML(Array(raw.utf8))
        XCTAssertEqual(doc.root.name, "t")
        XCTAssertEqual(doc.root.text(), "ok")
    }

    func testTruncatedDocumentFoldsUp() throws {
        // Unclosed elements: the partial content is still usable.
        let doc = try parseXML(Array("<r><a><b x=\"1\"/><c>tail".utf8))
        XCTAssertEqual(doc.root.name, "r")
        let a = doc.root.child("a")!
        XCTAssertEqual(a.child("b")?.attr("x"), "1")
        XCTAssertEqual(a.child("c")?.text(), "tail")
    }

    func testContentAfterRootIsIgnored() throws {
        let doc = try parseXML(Array("<r/><stray/>".utf8))
        XCTAssertEqual(doc.root.name, "r")
        XCTAssertEqual(doc.root.children.count, 0)
    }

    func testOverLimitSubtreeIsDroppedWholeAndSiblingsSurvive() {
        // Over the depth bound the over-limit subtree is dropped whole — its
        // siblings must stay siblings (a naive drop would let the skipped
        // subtree's end tags pop them off the stack instead).
        var deep = "<r><keep k=\"1\"/>"
        for i in 0..<300 { deep += "<d\(i)>" }        // nesting past MAX_DEPTH
        deep += "<deep>lost</deep>"
        for _ in 0..<300 { deep += "</x>" }           // close them all
        deep += "<keep2 k=\"2\"/></r>"
        let doc = try! parseXML(Array(deep.utf8))
        XCTAssertEqual(doc.root.childrenNamed("keep").count, 1)
        XCTAssertEqual(doc.root.childrenNamed("keep2").count, 1)
        XCTAssertEqual(doc.root.childrenNamed("keep2").first?.attr("k"), "2")
        XCTAssertTrue(doc.root.find("deep") == nil, "over-limit subtree must not survive")
    }

    func testEmptyElementsAndTextMerging() throws {
        let doc = try parseXML(Array("<r>a<!--c-->b</r>".utf8))
        // Text either side of a comment merges into one run.
        XCTAssertEqual(doc.root.children.count, 1)
        if case .text(let t)? = doc.root.children.first { XCTAssertEqual(t, "ab") } else { XCTFail("expected text") }
    }

    // MARK: - attribute lookup rules

    func testAttrLocalNameRules() throws {
        let doc = try parseXML(Array("<e id=\"plain\" r:id=\"rel\" xmlns:q=\"urn:x\"/>".utf8))
        XCTAssertEqual(doc.root.attr("id"), "plain", "plain name prefers the exact plain attr")
        XCTAssertEqual(doc.root.attr("r:id"), "rel")
        XCTAssertEqual(doc.root.attr("q:id"), "rel", "qualified lookup matches any prefix")
        let doc2 = try parseXML(Array("<e r:id=\"rel\"/>".utf8))
        XCTAssertEqual(doc2.root.attr("id"), "rel", "plain name falls back to the local name")
        XCTAssertEqual(doc2.root.attr("r:id"), "rel")
        let doc3 = try parseXML(Array("<e xmlns:id=\"v\"/>".utf8))
        XCTAssertNil(doc3.root.attr("id"), "xmlns decls are never attribute matches")
    }

    // MARK: - numeric / boolean attribute helpers

    func testNumericAndBoolAttrs() throws {
        let doc = try parseXML(Array("<e i=\"42\" f=\"1.0\" neg=\"-7\" big=\"9.5e18\" nan=\"nan\" b1=\"1\" b0=\"0\" bon=\"on\"/>".utf8))
        XCTAssertEqual(doc.root.i64("i"), 42)
        XCTAssertEqual(doc.root.i64("f"), 1, "producers write 1.0 for one")
        XCTAssertEqual(doc.root.i64("neg"), -7)
        // 9.5e18 parses as a float, clamps into range (the Rust clamp), so it
        // reads back as 9e18 — not nil.
        XCTAssertEqual(doc.root.i64("big"), 9_000_000_000_000_000_000)
        XCTAssertNil(doc.root.i64("nan"))
        XCTAssertNil(doc.root.i64("missing"))
        XCTAssertEqual(doc.root.i32("i"), 42)
        XCTAssertEqual(doc.root.u32("i"), UInt32(42))
        XCTAssertEqual(doc.root.f64("f"), 1.0)
        XCTAssertNil(doc.root.f64("nan"))
        XCTAssertEqual(doc.root.bool("b1"), true)
        XCTAssertEqual(doc.root.bool("b0"), false)
        XCTAssertEqual(doc.root.bool("bon"), true)
        XCTAssertNil(doc.root.bool("missing"))
    }

    func testPathFindFindAllText() throws {
        let raw = "<r><a><b><t>1</t></b><b><t>2</t></b></a><b><t>3</t></b></r>"
        let doc = try parseXML(Array(raw.utf8))
        XCTAssertEqual(doc.root.path(["a", "b", "t"])?.text(), "1")
        XCTAssertEqual(doc.root.findAll("b").count, 3, "find all descendants, document order")
        XCTAssertEqual(doc.root.findAll("t").map { $0.text() }, ["1", "2", "3"])
        XCTAssertEqual(doc.root.child("b")?.text(), "3", "child() is direct children only")
        XCTAssertEqual(doc.root.childVal("b"), nil)
        XCTAssertEqual(doc.root.path(["a", "missing"]), nil)
    }

    func testUTF16Part() throws {
        var bytes: [UInt8] = [0xFF, 0xFE] // LE BOM
        let body = "<t>ok</t>"
        for u in body.utf16 {
            bytes.append(UInt8(u & 0xFF))
            bytes.append(UInt8(u >> 8))
        }
        let doc = try parseXML(bytes)
        XCTAssertEqual(doc.root.name, "t")
        XCTAssertEqual(doc.root.text(), "ok")
    }

    // MARK: - Color

    func testHexParsing() {
        XCTAssertEqual(Rgba.fromHex("FF0000"), Rgba(r: 255, g: 0, b: 0))
        XCTAssertEqual(Rgba.fromHex("#00ff00"), Rgba(r: 0, g: 255, b: 0))
        XCTAssertEqual(Rgba.fromHex("11223344"), Rgba(r: 0x11, g: 0x22, b: 0x33, a: 0x44))
        XCTAssertEqual(Rgba.fromHex("#F0A"), Rgba(r: 255, g: 0, b: 170))
        XCTAssertNil(Rgba.fromHex("12345"))
        XCTAssertNil(Rgba.fromHex("zzzzzz"))
        XCTAssertNil(Rgba.fromHex(""))
    }

    func testHexFormat() {
        XCTAssertEqual(Rgba(r: 255, g: 0, b: 16).hex, "FF0010")
    }

    func testF64Clamps() {
        XCTAssertEqual(Rgba.fromF64(1.5, -0.5, 0.5, 1.0), Rgba(r: 255, g: 0, b: 128))
        XCTAssertEqual(Rgba.fromF64(.nan, 0, 0, 1), Rgba(r: 0, g: 0, b: 0))
    }

    func testLuminanceAndContrast() {
        XCTAssertEqual(Rgba.white.luminance(), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Rgba.black.luminance(), 0.0, accuracy: 1e-9)
        XCTAssertEqual(Rgba.white.contrast(Rgba.black), 21.0, accuracy: 0.05)
        XCTAssertEqual(Rgba.white.contrast(Rgba.white), 1.0, accuracy: 1e-9)
    }

    func testHSLRoundTrip() {
        for (r, g, b) in [(255u8, 0u8, 0u8), (0, 255, 0), (0, 0, 255), (128, 128, 128), (255, 255, 0), (10, 200, 130)] {
            let c = Rgba(r: r, g: g, b: b)
            let (h, s, l) = c.toHSL()
            let back = Rgba.fromHSL(h, s, l, 255)
            XCTAssertEqual(Double(back.r), Double(r), accuracy: 1)
            XCTAssertEqual(Double(back.g), Double(g), accuracy: 1)
            XCTAssertEqual(Double(back.b), Double(b), accuracy: 1)
        }
        XCTAssertEqual(Rgba.fromHSL(240, 1, 0.5, 255), Rgba(r: 0, g: 0, b: 255))
    }

    func testLerp() {
        let a = Rgba(r: 0, g: 0, b: 0), b = Rgba(r: 100, g: 200, b: 50)
        XCTAssertEqual(a.lerp(b, 0.5), Rgba(r: 50, g: 100, b: 25))
        XCTAssertEqual(a.lerp(b, -1), a, "t clamps")
        XCTAssertEqual(a.lerp(b, 2), b)
    }

    func testColorTransforms() {
        // Tint/shade apply in linear light; on pure grey the sRGB-linear maps
        // keep the result grey.
        let grey = Rgba(r: 128, g: 128, b: 128)
        let tinted = colorApply(grey, [.tint(50_000)])
        XCTAssertEqual(tinted.r, tinted.g)
        XCTAssertEqual(tinted.g, tinted.b)
        XCTAssertGreaterThan(tinted.r, 128, "tint 50% pulls half way to white")
        let shaded = colorApply(grey, [.shade(50_000)])
        XCTAssertLessThan(shaded.r, 128)

        let alphaed = colorApply(Rgba(r: 1, g: 2, b: 3), [.alpha(50_000)])
        XCTAssertEqual(alphaed.a, 128)

        XCTAssertEqual(colorApply(Rgba(r: 10, g: 20, b: 30), [.inv]), Rgba(r: 245, g: 235, b: 225))
        XCTAssertEqual(colorApply(Rgba(r: 255, g: 0, b: 0), [.gray]), Rgba(r: 76, g: 76, b: 76))

        // lumMod/lumOff ride HSL lightness.
        let white = colorApply(Rgba.white, [.lumOff(50_000)])
        XCTAssertEqual(white, Rgba.white, "lightness clamps at white")

        // From-XML mapping round-trips.
        XCTAssertEqual(ColorTransform.fromXML("lumMod", 60_000), .lumMod(60_000))
        XCTAssertEqual(ColorTransform.fromXML("comp", nil), .comp)
        XCTAssertNil(ColorTransform.fromXML("nope", nil))
        XCTAssertEqual(ColorTransform.lumMod(60_000).xmlName, "lumMod")
        XCTAssertEqual(ColorTransform.comp.value, nil)
    }

    func testSchemeSlots() {
        XCTAssertEqual(SchemeSlot.fromXML("accent1"), .accent1)
        XCTAssertEqual(SchemeSlot.fromXML("phClr"), .phClr)
        XCTAssertNil(SchemeSlot.fromXML("nope"))
        XCTAssertEqual(SchemeSlot.theme.count, 12)
        XCTAssertEqual(SchemeSlot.bg1.xmlName, "bg1")
    }

    func testPresetColors() {
        XCTAssertEqual(presetColor("red"), Rgba(r: 255, g: 0, b: 0))
        XCTAssertEqual(presetColor("fuchsia"), Rgba(r: 255, g: 0, b: 255))
        XCTAssertNil(presetColor("nope"))
    }
}
