// DeckTests.swift — the deck read path's contract tests, against an
// in-memory PPTX built here byte by byte (stored zip entries; the stored
// writer needs no deflate). The fixture is the whole port's spine: slide
// order through presentation.xml rels, EMU geometry, the placeholder
// inheritance chain (a slide title with no box of its own lands on the
// MASTER title's box through the layout), theme colours through shape style
// refs (fillRef idx with phClr), pictures through slide rels, tables with
// spans, the speakable text with its byte spans, and the HTML the viewer
// loads.

import XCTest
@testable import SlideDeckKit

final class DeckTests: XCTestCase {

    // MARK: - Zip plumbing

    /// Builds a stored (uncompressed) zip from name/data pairs.
    func zipBytes(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        for (name, payload) in entries {
            let crc = DeckZip.crc32([UInt8](payload))
            let offset = out.count
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // local header
            out.append(contentsOf: UInt16(20).littleBytes)               // version
            out.append(contentsOf: UInt16(0).littleBytes)                // flags
            out.append(contentsOf: UInt16(0).littleBytes)                // method: stored
            out.append(contentsOf: UInt16(0).littleBytes)                // time
            out.append(contentsOf: UInt16(0).littleBytes)                // date
            out.append(contentsOf: UInt32(crc).littleBytes)
            out.append(contentsOf: UInt32(payload.count).littleBytes)    // compressed
            out.append(contentsOf: UInt32(payload.count).littleBytes)    // uncompressed
            out.append(contentsOf: UInt16(name.utf8.count).littleBytes)
            out.append(contentsOf: UInt16(0).littleBytes)                // extra len
            out.append(contentsOf: Array(name.utf8))
            out.append(payload)
            central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            central.append(contentsOf: UInt16(20).littleBytes)
            central.append(contentsOf: UInt16(20).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt32(crc).littleBytes)
            central.append(contentsOf: UInt32(payload.count).littleBytes)
            central.append(contentsOf: UInt32(payload.count).littleBytes)
            central.append(contentsOf: UInt16(name.utf8.count).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt16(0).littleBytes)
            central.append(contentsOf: UInt32(0).littleBytes)
            central.append(contentsOf: UInt32(offset).littleBytes)
            central.append(contentsOf: Array(name.utf8))
        }
        let centralStart = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        out.append(contentsOf: UInt16(0).littleBytes)
        out.append(contentsOf: UInt16(0).littleBytes)
        out.append(contentsOf: UInt16(entries.count).littleBytes)
        out.append(contentsOf: UInt16(entries.count).littleBytes)
        out.append(contentsOf: UInt32(central.count).littleBytes)
        out.append(contentsOf: UInt32(centralStart).littleBytes)
        out.append(contentsOf: UInt16(0).littleBytes)
        return out
    }

    /// A fixed-Huffman DEFLATE block encoding `s` (lengths ≤ 7 verify the
    /// literal path; the dynamic path shares the same symbol machinery).
    func deflateFixed(_ s: String) -> Data {
        var bits: [Int] = []
        func emit(_ value: Int, _ count: Int) {
            // Huffman codes ride the LSB-first stream MSB-first.
            for i in stride(from: count - 1, through: 0, by: -1) {
                bits.append((value >> i) & 1)
            }
        }
        func litCode(_ c: Int) -> (Int, Int) {
            if c < 144 { return (0x30 + c, 8) }
            if c < 256 { return (0x190 + c, 9) }
            if c < 280 { return (c - 256, 7) }
            return (0xC0 + c, 8)
        }
        bits.append(1) // BFINAL
        bits.append(1) // fixed Huffman
        bits.append(0)
        for b in s.utf8 {
            let (code, len) = litCode(Int(b))
            emit(code, len)
        }
        emit(256, 7) // end of block
        var out = [UInt8]()
        var acc = 0
        var n = 0
        for b in bits {
            acc |= b << n
            n += 1
            if n == 8 {
                out.append(UInt8(acc))
                acc = 0
                n = 0
            }
        }
        if n > 0 { out.append(UInt8(acc)) }
        return Data(out)
    }

    func testZipStoredAndDeflateRoundtrip() throws {
        let payload = Data("stored bytes".utf8)
        let zip = zipBytes([("a/stored.txt", payload)])
        let entries = try DeckZip.entries(in: zip)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(try DeckZip.readEntry("a/stored.txt", in: zip), payload)

        // A deflated entry, built by hand below (method 8, raw DEFLATE).
        let text = "hello world"
        let deflated = deflateFixed(text)
        var manual = Data()
        var central = Data()
        let name = "a/deflated.bin"
        let crc = DeckZip.crc32([UInt8](Data(text.utf8)))
        let offset = 0
        manual.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        manual.append(contentsOf: UInt16(20).littleBytes)
        manual.append(contentsOf: UInt16(0).littleBytes)
        manual.append(contentsOf: UInt16(8).littleBytes) // deflate
        manual.append(contentsOf: UInt16(0).littleBytes)
        manual.append(contentsOf: UInt16(0).littleBytes)
        manual.append(contentsOf: UInt32(crc).littleBytes)
        manual.append(contentsOf: UInt32(deflated.count).littleBytes)
        manual.append(contentsOf: UInt32(text.utf8.count).littleBytes)
        manual.append(contentsOf: UInt16(name.utf8.count).littleBytes)
        manual.append(contentsOf: UInt16(0).littleBytes)
        manual.append(contentsOf: Array(name.utf8))
        manual.append(deflated)
        central.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        central.append(contentsOf: UInt16(20).littleBytes)
        central.append(contentsOf: UInt16(20).littleBytes)
        central.append(contentsOf: UInt16(0).littleBytes)
        central.append(contentsOf: UInt16(8).littleBytes)
        central.append(contentsOf: UInt16(0).littleBytes)
        central.append(contentsOf: UInt16(0).littleBytes)
        central.append(contentsOf: UInt32(crc).littleBytes)
        central.append(contentsOf: UInt32(deflated.count).littleBytes)
        central.append(contentsOf: UInt32(text.utf8.count).littleBytes)
        central.append(contentsOf: UInt16(name.utf8.count).littleBytes)
        central.append(contentsOf: UInt16(0).littleBytes)
        central.append(contentsOf: UInt16(0).littleBytes)
        central.append(contentsOf: UInt16(0).littleBytes)
        central.append(contentsOf: UInt16(0).littleBytes)
        central.append(contentsOf: UInt32(0).littleBytes)
        central.append(contentsOf: UInt32(offset).littleBytes)
        central.append(contentsOf: Array(name.utf8))
        let centralStart = manual.count
        manual.append(central)
        manual.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        manual.append(contentsOf: UInt16(0).littleBytes)
        manual.append(contentsOf: UInt16(0).littleBytes)
        manual.append(contentsOf: UInt16(1).littleBytes)
        manual.append(contentsOf: UInt16(1).littleBytes)
        manual.append(contentsOf: UInt32(central.count).littleBytes)
        manual.append(contentsOf: UInt32(centralStart).littleBytes)
        manual.append(contentsOf: UInt16(0).littleBytes)
        XCTAssertEqual(try DeckZip.readEntry(name, in: manual), Data(text.utf8))
    }

    // MARK: - The fixture deck

    let aNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    let pNS = "http://schemas.openxmlformats.org/presentationml/2006/main"
    let rNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A 1×1 PNG (a real image header, so the content type and decode path
    /// see honest bytes).
    let png1x1 = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    func zipOfFixture() -> Data {
        do {
            let d = try fixtureDeckBytes()
            return d
        } catch { fatalError("\(error)") }
    }

    func fixtureDeckBytes() throws -> Data {
        let presentation = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="\(aNS)" xmlns:r="\(rNS)" xmlns:p="\(pNS)">
          <sldMasterIdLst><sldMasterId id="2147483648" r:id="rId1"/></sldMasterIdLst>
          <sldIdLst><sldId id="256" r:id="rId2"/><sldId id="257" r:id="rId3"/></sldIdLst>
          <sldSz cx="9144000" cy="5143500"/>
          <defaultTextStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></defaultTextStyle>
        </p:presentation>
        """
        let presentationRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
        </Relationships>
        """
        let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>Quarterly Review</dc:title><dc:creator>Ada Lovelace</dc:creator>
        </cp:coreProperties>
        """
        let theme = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="\(aNS)" name="Test Theme">
          <a:themeElements>
            <a:clrScheme name="Test">
              <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
              <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
              <a:dk2><a:srgbClr val="111111"/></a:dk2>
              <a:lt2><a:srgbClr val="EEEEEE"/></a:lt2>
              <a:accent1><a:srgbClr val="FF0000"/></a:accent1>
              <a:accent2><a:srgbClr val="00FF00"/></a:accent2>
              <a:accent3><a:srgbClr val="0000FF"/></a:accent3>
              <a:accent4><a:srgbClr val="FFFF00"/></a:accent4>
              <a:accent5><a:srgbClr val="00FFFF"/></a:accent5>
              <a:accent6><a:srgbClr val="FF00FF"/></a:accent6>
              <a:hlink><a:srgbClr val="0000EE"/></a:hlink>
              <a:folHlink><a:srgbClr val="551A8B"/></a:folHlink>
            </a:clrScheme>
            <a:fontScheme name="Test">
              <a:majorFont><a:latin typeface="Major Face"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
              <a:minorFont><a:latin typeface="Minor Face"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
            </a:fontScheme>
            <a:fmtScheme name="Test">
              <a:fillStyleLst>
                <a:solidFill><a:schemeClr val="accent2"/></a:solidFill>
                <a:solidFill><a:schemeClr val="accent3"/></a:solidFill>
                <a:solidFill><a:schemeClr val="accent4"/></a:solidFill>
              </a:fillStyleLst>
              <a:lnStyleLst>
                <a:ln w="12700"><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:ln>
                <a:ln w="25400"><a:solidFill><a:schemeClr val="accent2"/></a:solidFill></a:ln>
                <a:ln w="38100"><a:solidFill><a:schemeClr val="accent3"/></a:solidFill></a:ln>
              </a:lnStyleLst>
              <a:effectStyleLst>
                <a:effectStyle><a:effectLst/></a:effectStyle>
                <a:effectStyle><a:effectLst/></a:effectStyle>
                <a:effectStyle><a:effectLst/></a:effectStyle>
              </a:effectStyleLst>
              <a:bgFillStyleLst>
                <a:solidFill><a:schemeClr val="bg1"/></a:solidFill>
                <a:solidFill><a:schemeClr val="accent1"/></a:solidFill>
                <a:solidFill><a:schemeClr val="accent2"/></a:solidFill>
              </a:bgFillStyleLst>
            </a:fmtScheme>
          </a:themeElements>
        </a:theme>
        """
        // The master: title and body placeholders WITH boxes and text
        // styles; the layout's title placeholder carries NO box, so the
        // slide's title (also boxless) must land on the MASTER's title box
        // through the two-step chain.
        let master = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="\(aNS)" xmlns:r="\(rNS)" xmlns:p="\(pNS)">
          <p:cSld>
            <p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
            <p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm/></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Title Placeholder"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="457200" y="914400"/><a:ext cx="8229600" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
                <p:style><a:lnRef idx="0"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="0"><a:schemeClr val="accent1"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="major"><a:schemeClr val="tx1"/></a:fontRef></p:style>
                <p:txBody><a:bodyPr anchor="b"/><a:lstStyle/><a:p/></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Body Placeholder"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="457200" y="2057400"/><a:ext cx="8229600" cy="2746380"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
          <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
          <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
          <p:txStyles>
            <p:titleStyle>
              <a:lvl1pPr algn="ctr"><a:defRPr sz="4400" b="1"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/></a:defRPr></a:lvl1pPr>
            </p:titleStyle>
            <p:bodyStyle>
              <a:lvl1pPr marL="342900" indent="-342900"><a:buChar char="•"/><a:defRPr sz="2800"/></a:lvl1pPr>
              <a:lvl2pPr marL="742950" indent="-285750"><a:buChar char="-"/><a:defRPr sz="2400"/></a:lvl2pPr>
            </p:bodyStyle>
            <p:otherStyle>
              <a:lvl1pPr><a:defRPr sz="1400"/></a:lvl1pPr>
            </p:otherStyle>
          </p:txStyles>
        </p:sldMaster>
        """
        let masterRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
        // The layout: a title placeholder with NO box (inherits the
        // master's), a body placeholder WITH a box.
        let layout = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="\(aNS)" xmlns:r="\(rNS)" xmlns:p="\(pNS)" type="obj">
          <p:cSld name="Title and Content">
            <p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm/></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Content"/><p:cNvSpPr/><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
                <p:spPr><a:xfrm><a:off x="457200" y="1828800"/><a:ext cx="8229600" cy="2971800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
          <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
        let layoutRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
        // Slide 1: title (boxless — the inheritance test), an accent-filled
        // rect with a dashed border, an ellipse through its style's fillRef
        // (phClr), a picture, a table with a span, a text box anchored
        // bottom with a blank second paragraph, a connector.
        let slide1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="\(aNS)" xmlns:r="\(rNS)" xmlns:p="\(pNS)" showMasterSp="0">
          <p:cSld>
            <p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm/></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="3200"/><a:t>Hello Deck</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="3" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="457200" y="4572000"/><a:ext cx="1828800" cy="457200"/></a:xfrm>
                  <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                  <a:solidFill><a:schemeClr val="accent1"/></a:solidFill>
                  <a:ln w="19050"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:prstDash val="dash"/></a:ln>
                </p:spPr>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Boxed</a:t></a:r></a:p></p:txBody>
              </p:sp>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="4" name="Pill"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="2743200" y="4572000"/><a:ext cx="1828800" cy="457200"/></a:xfrm>
                  <a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>
                </p:spPr>
                <p:style><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="1"><a:schemeClr val="accent2"/></a:fillRef><a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="tx1"/></a:fontRef></p:style>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody>
              </p:sp>
              <p:pic>
                <p:nvPicPr><p:cNvPr id="5" name="Photo"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
                <p:spPr><a:xfrm><a:off x="5029200" y="4572000"/><a:ext cx="914400" cy="457200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
              </p:pic>
              <p:graphicFrame>
                <p:nvGraphicFramePr><p:cNvPr id="6" name="Numbers"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
                <p:xfrm><a:off x="6400800" y="4572000"/><a:ext cx="2286000" cy="457200"/></p:xfrm>
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">
                  <a:tbl>
                    <a:tblGrid><a:gridCol w="762000"/><a:gridCol w="762000"/><a:gridCol w="762000"/></a:tblGrid>
                    <a:tr h="228600">
                      <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>A1</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>
                      <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>B1</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>
                      <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>C1</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>
                    </a:tr>
                    <a:tr h="228600">
                      <a:tc gridSpan="2"><a:txBody><a:bodyPr/><a:p><a:r><a:t>A2</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>
                      <a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>C2</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>
                    </a:tr>
                  </a:tbl>
                </a:graphicData></a:graphic>
              </p:graphicFrame>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="7" name="Caption"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="457200" y="365760"/><a:ext cx="2743200" cy="457200"/></a:xfrm>
                  <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/>
                </p:spPr>
                <p:txBody><a:bodyPr wrap="none" anchor="b"/><a:lstStyle/>
                  <a:p><a:r><a:rPr lang="en-US" b="1" i="1"><a:solidFill><a:srgbClr val="3366CC"/></a:solidFill></a:rPr><a:t>Bold caption</a:t></a:r></a:p>
                  <a:p><a:endParaRPr lang="en-US" sz="1200"/></a:p>
                </p:txBody>
              </p:sp>
              <p:cxnSp>
                <p:nvCxnSpPr><p:cNvPr id="8" name="Line"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>
                <p:spPr>
                  <a:xfrm><a:off x="914400" y="2743200"/><a:ext cx="1828800" cy="914400"/></a:xfrm>
                  <a:prstGeom prst="straightConnector1"><a:avLst/></a:prstGeom>
                  <a:ln w="28575"><a:solidFill><a:schemeClr val="accent6"/></a:solidFill></a:ln>
                </p:spPr>
              </p:cxnSp>
            </p:spTree>
          </p:cSld>
          <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
        let slide1Rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide1.xml"/>
        </Relationships>
        """
        // Slide 2 exists to prove the ORDER follows sldIdLst, not file names.
        let slide2 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="\(aNS)" xmlns:r="\(rNS)" xmlns:p="\(pNS)">
          <p:cSld>
            <p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm/></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Second Slide</a:t></a:r></a:p></p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:sld>
        """
        let slide2Rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        </Relationships>
        """
        let notes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes xmlns:a="\(aNS)" xmlns:r="\(rNS)" xmlns:p="\(pNS)">
          <p:cSld>
            <p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr><a:xfrm/></p:grpSpPr>
              <p:sp>
                <p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr/><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>
                <p:spPr/>
                <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Speaker says hello</a:t></a:r></a:p></p:txBody>
              </p:sp>
            </p:spTree>
          </p:cSld>
        </p:notes>
        """
        let notesRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="png" ContentType="image/png"/>
          <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """
        let zip = zipBytes([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("docProps/core.xml", Data(core.utf8)),
            ("ppt/presentation.xml", Data(presentation.utf8)),
            ("ppt/_rels/presentation.xml.rels", Data(presentationRels.utf8)),
            ("ppt/theme/theme1.xml", Data(theme.utf8)),
            ("ppt/slideMasters/slideMaster1.xml", Data(master.utf8)),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(masterRels.utf8)),
            ("ppt/slideLayouts/slideLayout1.xml", Data(layout.utf8)),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(layoutRels.utf8)),
            ("ppt/slides/slide1.xml", Data(slide1.utf8)),
            ("ppt/slides/_rels/slide1.xml.rels", Data(slide1Rels.utf8)),
            ("ppt/slides/slide2.xml", Data(slide2.utf8)),
            ("ppt/slides/_rels/slide2.xml.rels", Data(slide2Rels.utf8)),
            ("ppt/notesSlides/notesSlide1.xml", Data(notes.utf8)),
            ("ppt/notesSlides/_rels/notesSlide1.xml.rels", Data(notesRels.utf8)),
            ("ppt/media/image1.png", png1x1),
        ])
        return zip
    }

    func fixtureDeck() throws -> SlideDeck {
        try DeckParser.parse(try fixtureDeckBytes())
    }

    // MARK: - The contract

    func testSlideOrderSizeAndMetadata() throws {
        let deck = try fixtureDeck()
        XCTAssertEqual(deck.w, 720, accuracy: 0.01)
        XCTAssertEqual(deck.h, 405, accuracy: 0.01)
        XCTAssertEqual(deck.slides.count, 2)
        XCTAssertEqual(deck.title, "Quarterly Review")
        XCTAssertEqual(deck.author, "Ada Lovelace")
        XCTAssertEqual(deck.slides[0].title, "Hello Deck")
        XCTAssertEqual(deck.slides[1].title, "Second Slide")
        XCTAssertEqual(deck.media.count, 1, "the one PNG is the only serveable media")
        XCTAssertEqual(deck.media[0].contentType, "image/png")
    }

    /// The title placeholder carries no box of its own on the slide or the
    /// layout: its box must arrive from the MASTER title through the chain.
    func testPlaceholderInheritanceLandsOnTheMasterBox() throws {
        let deck = try fixtureDeck()
        let slide = deck.slides[0]
        // The slide shows no master shapes (showMasterSp="0"), so the first
        // item IS the slide's own title shape.
        let title = slide.items.first
        XCTAssertNotNil(title)
        XCTAssertEqual(title?.x ?? 0, 36, accuracy: 0.01)
        XCTAssertEqual(title?.y ?? 0, 72, accuracy: 0.01)
        XCTAssertEqual(title?.w ?? 0, 648, accuracy: 0.01)
        XCTAssertEqual(title?.h ?? 0, 72, accuracy: 0.01)
        // The run: 32 pt explicit, bold from the master's titleStyle, the
        // theme's major font, centred.
        guard case .text(let paras, let anchor, _, _) = title?.content else {
            return XCTFail("the title is a text item")
        }
        XCTAssertEqual(anchor, .bottom, "the master's bodyPr anchor=b rides the chain")
        let run = paras[0].runs[0]
        XCTAssertEqual(run.text, "Hello Deck")
        XCTAssertEqual(run.size, 32, accuracy: 0.01)
        XCTAssertTrue(run.bold, "b=1 comes from the master titleStyle's lvl1 defRPr")
        XCTAssertEqual(run.font, "Major Face", "the title placeholder's fontRef is major")
        XCTAssertEqual(paras[0].align, "center")
    }

    func testExplicitFillBorderAndStyleRefs() throws {
        let deck = try fixtureDeck()
        let items = deck.slides[0].items
        // "Boxed": explicit accent1 fill + a dashed tx1 border.
        let boxed = items.first { item in
            if case .text(let paras, _, _, _) = item.content, paras.first?.runs.first?.text == "Boxed" { return true }
            return false
        }
        XCTAssertEqual(boxed?.fill, "#FF0000")
        XCTAssertEqual(boxed?.border?.style, "dashed")
        XCTAssertEqual(boxed?.border?.width ?? 0, 1.5, accuracy: 0.01)
        XCTAssertEqual(boxed?.border?.color, "#000000")
        XCTAssertEqual(boxed?.radius ?? 0, 0, accuracy: 0.01)
        XCTAssertNil(boxed?.svg, "a rect paints in CSS, no SVG body")

        // "Pill": no explicit fill — fillRef idx 1 resolves through the
        // theme's format fills (solid accent2) with phClr = accent2.
        let pill = items.first { item in
            if case .text(let paras, _, _, _) = item.content, paras.first?.runs.isEmpty == true { return item.svg != nil }
            return false
        }
        XCTAssertNotNil(pill, "the ellipse has an SVG body")
        XCTAssertEqual(pill?.svg?.fill, "#00FF00", "fillRef → theme fill → phClr resolved")
        XCTAssertEqual(pill?.svg?.d.contains("C"), true, "an ellipse outline is cubic arcs")
    }

    func testPictureMediaAndTable() throws {
        let deck = try fixtureDeck()
        let items = deck.slides[0].items
        var sawPicture = false
        var sawTable = false
        for item in items {
            switch item.content {
            case .picture(let media, let crop, _):
                sawPicture = true
                XCTAssertEqual(media, 0)
                XCTAssertEqual(crop, [0, 0, 0, 0])
            case .table(let cols, let heights, let rows, _):
                sawTable = true
                XCTAssertEqual(cols.count, 3)
                XCTAssertEqual(cols[0], 60, accuracy: 0.01) // 762000 EMU
                XCTAssertEqual(heights.count, 2)
                XCTAssertEqual(rows[0].cells[0].text, "A1")
                XCTAssertEqual(rows[0].cells[1].text, "B1")
                XCTAssertEqual(rows[1].cells[0].colSpan, 2)
                XCTAssertFalse(rows[1].cells[0].covered)
                XCTAssertEqual(rows[1].cells.count, 2, "the span's second column is the colspan's job")
                XCTAssertEqual(rows[1].cells[1].text, "C2")
            default:
                break
            }
        }
        XCTAssertTrue(sawPicture)
        XCTAssertTrue(sawTable)
    }

    func testTextBoxAnchorWrapBlankLineAndConnector() throws {
        let deck = try fixtureDeck()
        let items = deck.slides[0].items
        let caption = items.first { item in
            if case .text(let paras, _, _, _) = item.content, paras.first?.runs.first?.text == "Bold caption" { return true }
            return false
        }
        XCTAssertNotNil(caption)
        guard case .text(let paras, let anchor, let wrap, _) = caption?.content else {
            return XCTFail("the caption is a text item")
        }
        XCTAssertEqual(anchor, .bottom, "bodyPr anchor=b")
        XCTAssertEqual(wrap, false, "bodyPr wrap=none")
        XCTAssertEqual(paras[0].runs[0].bold, true)
        XCTAssertEqual(paras[0].runs[0].italic, true)
        XCTAssertEqual(paras[0].runs[0].color, "#3366CC")
        XCTAssertEqual(paras.count, 2)
        XCTAssertEqual(paras[1].emptySize, 12, accuracy: 0.01, "the blank line's end mark is 12 pt")

        // The connector: a line-like preset whose stroke rides the SVG body.
        let line = items.first { $0.svg?.stroke == "#FF00FF" }
        XCTAssertNotNil(line, "accent6 = FF00FF strokes the connector")
        XCTAssertEqual(line?.fill ?? "sentinel", "sentinel", "a connector fills nothing")
    }

    func testSpeakableTextAndSpans() throws {
        let deck = try fixtureDeck()
        let (text, spans) = DeckSlides.slideText(deck, 0)
        // z-order: title, box, pill (silent), picture (silent), table,
        // caption, connector (silent) — then the notes tail.
        XCTAssertTrue(text.hasPrefix("Hello Deck\nBoxed\nA1, B1, C1\nA2, C2\nBold caption"))
        XCTAssertTrue(text.hasSuffix("Speaker says hello"))
        XCTAssertEqual(spans.count, 6, "title, box, two table rows, caption, notes")
        XCTAssertEqual(spans[0].item, 0)
        XCTAssertEqual(spans[0].para, 0)
        let head = String(decoding: Array(text.utf8)[spans[0].start..<spans[0].end], as: UTF8.self)
        XCTAssertEqual(head, "Hello Deck")
        let notes = spans.last!
        XCTAssertEqual(notes.item, Int.max)
        let tail = String(decoding: Array(text.utf8)[notes.start..<notes.end], as: UTF8.self)
        XCTAssertEqual(tail, "Speaker says hello")
    }

    func testHTMLRenderer() throws {
        let deck = try fixtureDeck()
        let html = DeckHTML.deckHTML(deck)
        XCTAssertTrue(html.contains(#"data-w="720""#))
        XCTAssertTrue(html.contains(#"class="slide" id="s0""#))
        XCTAssertTrue(html.contains(#"id="i0p0" data-s="0""#), "the first paragraph is highlight target zero")
        XCTAssertTrue(html.contains("left:36pt;top:72pt;width:648pt;height:72pt"), "the inherited title box")
        XCTAssertTrue(html.contains("background:#FF0000"), "the accent1 box")
        XCTAssertTrue(html.contains("border:1.5pt dashed #000000"))
        XCTAssertTrue(html.contains(#"<svg class="shape""#), "ellipse + connector draw as SVG paths")
        XCTAssertTrue(html.contains("deck://media/0/"), "the picture rides the scheme handler")
        XCTAssertTrue(html.contains("deck://media/0/"), "the media name rides the URL too")
        XCTAssertTrue(html.contains("font-size:32pt"))
        XCTAssertTrue(html.contains("line-through") == false)
        XCTAssertFalse(html.contains("&amp;lt;"), "escaping stays single-pass")
    }

    func testNotesTailOnlyAfterNonEmptyNotes() throws {
        let deck = try fixtureDeck()
        let (text2, spans2) = DeckSlides.slideText(deck, 1)
        XCTAssertEqual(text2, "Second Slide")
        XCTAssertEqual(spans2.count, 1, "slide 2's title is its only speakable text")
        XCTAssertEqual(DeckSlides.slideText(deck, 99).0, "", "an out-of-range index speaks nothing")
    }
}

extension UInt16 {
    var littleBytes: [UInt8] { withUnsafeBytes(of: littleEndian, Array.init) }
}

extension UInt32 {
    var littleBytes: [UInt8] { withUnsafeBytes(of: littleEndian, Array.init) }
}

extension UInt16 {
    var littleBytes: [UInt8] { withUnsafeBytes(of: littleEndian, Array.init) }
}

extension UInt32 {
    var littleBytes: [UInt8] { withUnsafeBytes(of: littleEndian, Array.init) }
}

extension DeckTests {
    func testZZDebugDump() throws {
        let deck = try fixtureDeck()
        print("TITLE=\(deck.title) AUTHOR=\(deck.author)")
        // Core-props rel debug.
        let raw = zipOfFixture()
        let pkg = try Ooxml.Package.open(raw)
        for r in pkg.rels("").items {
            print("ROOTREL \(r.id) kind=\(r.kind) target=\(r.target) ext=\(r.external)")
        }
        print("COREXML present=\(pkg.xml("docProps/core.xml") != nil)")
        // Deflate zip debug: what did the central directory say?
        let deflated0 = deflateFixed("hello world")
        var manual0 = Data()
        var central0 = Data()
        let name0 = "a/deflated.bin"
        let crc0 = DeckZip.crc32([UInt8](Data("hello world".utf8)))
        manual0.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
        manual0.append(contentsOf: UInt16(20).littleBytes)
        manual0.append(contentsOf: UInt16(0).littleBytes)
        manual0.append(contentsOf: UInt16(8).littleBytes)
        manual0.append(contentsOf: UInt16(0).littleBytes)
        manual0.append(contentsOf: UInt16(0).littleBytes)
        manual0.append(contentsOf: UInt32(crc0).littleBytes)
        manual0.append(contentsOf: UInt32(deflated0.count).littleBytes)
        manual0.append(contentsOf: UInt32(11).littleBytes)
        manual0.append(contentsOf: UInt16(name0.utf8.count).littleBytes)
        manual0.append(contentsOf: UInt16(0).littleBytes)
        manual0.append(contentsOf: Array(name0.utf8))
        manual0.append(deflated0)
        central0.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
        central0.append(contentsOf: UInt16(20).littleBytes)
        central0.append(contentsOf: UInt16(20).littleBytes)
        central0.append(contentsOf: UInt16(0).littleBytes)
        central0.append(contentsOf: UInt16(8).littleBytes)
        central0.append(contentsOf: UInt16(0).littleBytes)
        central0.append(contentsOf: UInt16(0).littleBytes)
        central0.append(contentsOf: UInt32(crc0).littleBytes)
        central0.append(contentsOf: UInt32(deflated0.count).littleBytes)
        central0.append(contentsOf: UInt32(11).littleBytes)
        central0.append(contentsOf: UInt16(name0.utf8.count).littleBytes)
        central0.append(contentsOf: UInt16(0).littleBytes)
        central0.append(contentsOf: UInt16(0).littleBytes)
        central0.append(contentsOf: UInt16(0).littleBytes)
        central0.append(contentsOf: UInt16(0).littleBytes)
        central0.append(contentsOf: UInt32(0).littleBytes)
        central0.append(contentsOf: UInt32(0).littleBytes)
        central0.append(contentsOf: Array(name0.utf8))
        let cs0 = manual0.count
        manual0.append(central0)
        manual0.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        manual0.append(contentsOf: UInt16(0).littleBytes)
        manual0.append(contentsOf: UInt16(0).littleBytes)
        manual0.append(contentsOf: UInt16(1).littleBytes)
        manual0.append(contentsOf: UInt16(1).littleBytes)
        manual0.append(contentsOf: UInt32(central0.count).littleBytes)
        manual0.append(contentsOf: UInt32(cs0).littleBytes)
        manual0.append(contentsOf: UInt16(0).littleBytes)
        if let e0 = try? DeckZip.entries(in: manual0).first {
            print("DEFLATE ENTRY method=\(e0.method) comp=\(e0.compressedSize) uncomp=\(e0.uncompressedSize) crc=\(String(e0.crc, radix: 16)) localOff=\(e0.localHeaderOffset)")
            print("DEFLATED bytes=\(deflated0.map { String($0, radix: 16) }.joined(separator: " "))")
        }
        if let core = pkg.xml("docProps/core.xml") {
            for e in core.root.elements {
                print("CORE \(e.local) = \(e.text())")
            }
        }
        for (i, slide) in deck.slides.enumerated() {
            print("SLIDE\(i) title=\(slide.title) text=\(slide.text)")
        }
        for (i, item) in deck.slides[0].items.enumerated() {
            let desc: String
            switch item.content {
            case .text(let paras, let a, let w, let d):
                desc = "text paras=\(paras.count) runs=\(paras.first?.runs.count ?? -1) anchor=\(a) wrap=\(w) dir=\(d) first=\(paras.first?.runs.first?.text ?? "-")"
            case .picture(let m, _, _): desc = "picture m=\(m)"
            case .table(let c, _, let rows, _): desc = "table cols=\(c.count) rows=\(rows.count)"
            case .frame(let label, _): desc = "frame \(label)"
            }
            print("ITEM\(i) box=(\(item.x),\(item.y),\(item.w),\(item.h)) fill=\(item.fill ?? "-") svg=\(item.svg != nil) \(desc)")
        }
    }
}
