// DeckHTML.swift — the whole deck as one document: a section per slide over
// a stage sized in points, scaled to fit by the injected script. Port of the
// Linux app's sn-ui/src/slideview/document.rs + script.rs @ speechnotes-linux-rust,
// retargeted from WebKitGTK to iOS WKWebView: media rides the app's
// `deck://media/<index>` scheme handler (the Linux viewer's custom URL
// scheme), and the script posts `slidechanged:<n>` through the
// `snslides` message handler.

import Foundation

public enum DeckHTML {

    /// The URL scheme the viewer's media handler serves (`deck://media/…`).
    public static let mediaScheme = "deck"

    /// Build the whole deck as one HTML document.
    public static func deckHTML(_ deck: SlideDeck) -> String {
        var out = ""
        out += "<!DOCTYPE html><html data-w=\"\(num(deck.w))\" data-h=\"\(num(deck.h))\">"
        out += "<head><meta charset=\"utf-8\">"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, user-scalable=no\">"
        out += "<style>"
        out += ":root{--dw:\(num(deck.w));--dh:\(num(deck.h));}"
        out += deckCSS
        out += "</style></head><body><main class=\"deck\">"
        for (index, slide) in deck.slides.enumerated() {
            out += slideHTML(deck, index, slide)
        }
        out += "</main>"
        out += "<script>\(slidesScript)</script>"
        out += "</body></html>"
        return out
    }

    /// One slide: its stage and its items in z-order (document order).
    static func slideHTML(_ deck: SlideDeck, _ index: Int, _ slide: Slide) -> String {
        // The highlight targets: (item, para) → byte range for text
        // paragraphs, and per-item byte ranges for the whole-item shapes (a
        // table's rows) the paragraph form cannot address.
        var paraSpans: [Int64: (Int, Int)] = [:] // key: item * 1_000_000 + para
        var itemSpans: [Int: [(Int, Int)]] = [:]
        for span in slide.spans {
            if let para = span.para {
                paraSpans[Int64(span.item) * 1_000_000 + Int64(para)] = (span.start, span.end)
            } else if span.item != Int.max {
                itemSpans[span.item, default: []].append((span.start, span.end))
            }
        }

        var out = "<section class=\"slide\" id=\"s\(index)\"><div class=\"stage\" style=\"background:"
        out += slide.bg ?? "#FFFFFF"
        out += ";\">"
        for (i, item) in slide.items.enumerated() {
            out += itemHTML(deck, i, item, paraSpans, itemSpans[i])
        }
        out += "</div></section>"
        return out
    }

    /// One item: an absolutely-positioned box in points, with the shape's
    /// paint, border, shadow and geometry, and its content inside.
    static func itemHTML(
        _ deck: SlideDeck, _ index: Int, _ item: Item,
        _ paraSpans: [Int64: (Int, Int)], _ itemSpans: [(Int, Int)]?
    ) -> String {
        var style = "left:\(num(item.x))pt;top:\(num(item.y))pt;width:\(num(item.w))pt;height:\(num(item.h))pt"
        // Rotation is clockwise in both PowerPoint's and CSS's books. A flip
        // mirrors the shape; PowerPoint keeps a text box's words readable
        // through a flip, so the text body counter-scales below.
        var transform: [String] = []
        if item.rot != 0 {
            transform.append("rotate(\(num(item.rot))deg)")
        }
        let sx = item.flipH ? -1.0 : 1.0
        let sy = item.flipV ? -1.0 : 1.0
        if item.flipH || item.flipV {
            transform.append("scale(\(num(sx)),\(num(sy)))")
        }
        if !transform.isEmpty {
            style += ";transform:" + transform.joined(separator: " ")
        }
        if let fill = item.fill {
            style += ";background:" + fill
        }
        if let border = item.border {
            style += ";border:\(num(border.width))pt \(border.style) \(border.color)"
        }
        if item.radius > 0 {
            style += ";border-radius:\(num(item.radius))pt"
        }
        if let shadow = item.shadow {
            style += ";box-shadow:" + shadow
        }

        var out = "<div class=\"item\" id=\"i\(index)\" style=\"\(style)\">"
        // A table's whole-item spans go on its rows instead — an overlay here
        // would tint the whole table for one spoken row.
        if case .picture = item.content, let spans = itemSpans {
            for (start, end) in spans {
                out += "<span class=\"hit\" data-s=\"\(start)\" data-e=\"\(end)\"></span>"
            }
        }
        if let svg = item.svg {
            out += "<svg class=\"shape\" viewBox=\"0 0 \(num(item.w)) \(num(item.h))\" preserveAspectRatio=\"none\"><path d=\""
            out += escapeHTML(svg.d)
            out += "\" fill=\"\(svg.fill ?? "none")\" stroke=\"\(svg.stroke ?? "none")\" stroke-width=\"\(num(svg.strokeWidth))\"/></svg>"
        }
        out += contentHTML(deck, index, item, paraSpans, itemSpans)
        out += "</div>"
        return out
    }

    /// The item's content: text, picture, table or frame.
    static func contentHTML(
        _ deck: SlideDeck, _ index: Int, _ item: Item,
        _ paraSpans: [Int64: (Int, Int)], _ itemSpans: [(Int, Int)]?
    ) -> String {
        switch item.content {
        case .text(let paras, let anchor, let wrap, let dir):
            var style: [String] = []
            switch anchor {
            case .top: style.append("justify-content:flex-start")
            case .middle: style.append("justify-content:center")
            case .bottom: style.append("justify-content:flex-end")
            }
            // The standing directions, approximated with the writing modes
            // WebKit has: `vert270` (bottom-to-top) as a vertical run turned
            // upside down, `stacked` as upright letters.
            var transform: [String] = []
            switch dir {
            case "vert":
                style.append("writing-mode:vertical-rl")
            case "vert270":
                style.append("writing-mode:vertical-rl")
                transform.append("rotate(180deg)")
            case "stacked":
                style.append("writing-mode:vertical-rl;text-orientation:upright")
            default:
                break
            }
            // PowerPoint keeps flipped text readable: un-mirror it. One
            // transform property, whatever the direction asked for too.
            if item.flipH || item.flipV {
                transform.append("scale(\(num(item.flipH ? -1.0 : 1.0)),\(num(item.flipV ? -1.0 : 1.0)))")
            }
            if !transform.isEmpty {
                style.append("transform:" + transform.joined(separator: " "))
            }
            let insets: String
            if case .text = item.content {
                insets = ";padding:3.6pt 7.2pt"
            } else {
                insets = ""
            }
            var out = "<div class=\"tb\" style=\"\(style.joined(separator: ";"))\(insets);white-space:\(wrap ? "pre-wrap" : "nowrap")\">"
            for (para, p) in paras.enumerated() {
                out += paraHTML(deck, index, para, p, paraSpans)
            }
            out += "</div>"
            return out
        case .picture(let media, let crop, _):
            return pictureHTML(deck, media, crop, item)
        case .table(let colWidths, let rowHeights, let rows, let bg):
            return tableHTML(colWidths, rowHeights, rows, bg, itemSpans)
        case .frame(let label, let media):
            var out = "<div class=\"frame\">"
            if let media {
                out += posterImg(deck, media)
            }
            if !label.trimmingCharacters(in: .whitespaces).isEmpty {
                out += "<div class=\"frame-label\">\(escapeHTML(label))</div>"
            }
            out += "</div>"
            return out
        }
    }

    /// A picture, with the deck's crop honoured: the crop fractions inset the
    /// image inside its frame, so the frame shows exactly the cropped region.
    static func pictureHTML(_ deck: SlideDeck, _ media: Int, _ crop: [Double], _ item: Item) -> String {
        guard let src = mediaSrc(deck, media) else { return "" }
        let l = crop.count > 0 ? crop[0] : 0
        let t = crop.count > 1 ? crop[1] : 0
        let r = crop.count > 2 ? crop[2] : 0
        let b = crop.count > 3 ? crop[3] : 0
        if l <= 0 && t <= 0 && r <= 0 && b <= 0 {
            return "<img class=\"pic\" src=\"\(src)\" alt=\"\">"
        }
        // The visible fraction of each axis: the image is blown up by
        // 1/(1−crops) and slid so the cropped region fills the frame.
        let spanW = max(1 - l - r, 0.05)
        let spanH = max(1 - t - b, 0.05)
        return "<span class=\"picwrap\"><img class=\"pic\" src=\"\(src)\" alt=\"\" style=\"position:absolute;left:-\(num(l * item.w))pt;top:-\(num(t * item.h))pt;width:\(num(item.w / spanW))pt;height:\(num(item.h / spanH))pt;max-width:none\"></span>"
    }

    /// A table: real rows and cells, the deck's column widths and row
    /// heights, one highlight target per row that says something.
    static func tableHTML(
        _ colWidths: [Double], _ rowHeights: [Double], _ rows: [TableRow],
        _ bg: String?, _ itemSpans: [(Int, Int)]?
    ) -> String {
        var out = "<div class=\"tblwrap\"><table style=\"table-layout:fixed;"
        if let bg {
            out += "background:" + bg
        }
        out += "\"><colgroup>"
        for w in colWidths {
            out += "<col style=\"width:\(num(w))pt\">"
        }
        out += "</colgroup>"
        // The speakable rows and the rendered rows line up one-to-one: the
        // text assembler skips the silent rows, and so does the row counter
        // below.
        var spanI = 0
        for (ri, row) in rows.enumerated() {
            var attrs = ""
            let speaks = row.cells.contains { !$0.covered && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if speaks, let spans = itemSpans, spanI < spans.count {
                let (start, end) = spans[spanI]
                attrs = " data-s=\"\(start)\" data-e=\"\(end)\""
            }
            let height = ri < rowHeights.count ? max(rowHeights[ri], 0) : 0
            out += "<tr style=\"height:\(num(height))pt\"\(attrs)>"
            for cell in row.cells {
                if cell.covered { continue }
                var attrs = ""
                if cell.colSpan > 1 {
                    attrs += " colspan=\"\(cell.colSpan)\""
                }
                if cell.rowSpan > 1 {
                    attrs += " rowspan=\"\(cell.rowSpan)\""
                }
                var style = "text-align:" + cell.align
                if let fill = cell.fill {
                    style += ";background:" + fill
                }
                out += "<td\(attrs) style=\"\(style)\">"
                if cell.runs.isEmpty && !cell.text.isEmpty {
                    out += escapeHTML(cell.text)
                } else {
                    out += runsHTML(cell.runs)
                }
                out += "</td>"
            }
            out += "</tr>"
            if speaks { spanI += 1 }
        }
        out += "</table></div>"
        return out
    }

    /// One paragraph of a text body: its own highlight target when it says
    /// something, its blank-line height when it does not.
    static func paraHTML(
        _ deck: SlideDeck, _ item: Int, _ para: Int, _ p: Para,
        _ paraSpans: [Int64: (Int, Int)]
    ) -> String {
        var style: [String] = []
        if p.runs.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            // A blank line keeps its place: the height of its end mark.
            if p.emptySize > 0 {
                return "<p style=\"min-height:\(num(p.emptySize))pt;margin:0\"></p>"
            }
            return "<p style=\"margin:0\"></p>"
        }
        style.append("text-align:\(p.align)")
        style.append("margin:\(num(p.spaceBefore))pt 0 \(num(p.spaceAfter))pt 0;margin-left:\(num(p.marginLeft))pt;text-indent:\(num(p.indent))pt")
        if p.linePts > 0 {
            style.append("line-height:\(num(p.linePts))pt")
        } else if p.linePct > 0 {
            style.append("line-height:\(num(p.linePct))")
        }
        let key = Int64(item) * 1_000_000 + Int64(para)
        var id = ""
        var data = ""
        if let (start, end) = paraSpans[key] {
            id = " id=\"i\(item)p\(para)\""
            data = " data-s=\"\(start)\" data-e=\"\(end)\""
        }
        var bullet = ""
        if let b = p.bullet {
            if let media = b.media {
                bullet = mediaSrc(deck, media).map { "<img class=\"blt-img\" src=\"\($0)\" alt=\"\">" } ?? ""
            } else {
                bullet = "<span class=\"blt\">\(escapeHTML(b.char))</span> "
            }
        }
        return "<p\(id)\(data) style=\"\(style.joined(separator: ";"))\">\(bullet)\(runsHTML(p.runs))</p>"
    }

    /// The runs of a paragraph or a cell, each with its own resolved type.
    static func runsHTML(_ runs: [Run]) -> String {
        var out = ""
        for run in runs {
            if run.text.isEmpty { continue }
            var style: [String] = []
            if run.size > 0 {
                style.append("font-size:\(num(run.size))pt")
            }
            if run.bold {
                style.append("font-weight:bold")
            }
            if run.italic {
                style.append("font-style:italic")
            }
            var deco: [String] = []
            if run.underline { deco.append("underline") }
            if run.strike { deco.append("line-through") }
            if !deco.isEmpty {
                style.append("text-decoration:" + deco.joined(separator: " "))
            }
            if let color = run.color {
                style.append("color:\(color)")
            }
            if !run.font.isEmpty {
                let family = run.font.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                style.append("font-family:\"\(family)\",sans-serif")
            }
            if run.spacing != 0 {
                style.append("letter-spacing:\(num(run.spacing))pt")
            }
            if run.baseline != 0 && run.size > 0 {
                style.append("vertical-align:\(num(run.baseline * run.size))pt")
            }
            if let highlight = run.highlight {
                style.append("background:\(highlight)")
            }
            out += "<span style=\"\(style.joined(separator: ";"))\">\(escapeHTML(run.text))</span>"
        }
        return out
    }

    /// The URL for a deck media index, or nothing when the index is out of
    /// range (the item renders empty rather than pointing at nothing).
    static func mediaSrc(_ deck: SlideDeck, _ media: Int) -> String? {
        guard media >= 0, media < deck.media.count else { return nil }
        let name = deck.media[media].name
            .addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))) ?? "img"
        return "\(mediaScheme)://media/\(media)/\(name)"
    }

    /// An `<img>` for a media index, object-fit contained (a poster inside a
    /// frame, a picture bullet).
    static func posterImg(_ deck: SlideDeck, _ media: Int) -> String {
        guard let src = mediaSrc(deck, media) else { return "" }
        return "<img src=\"\(src)\" alt=\"\">"
    }

    // -----------------------------------------------------------------------
    // Text helpers
    // -----------------------------------------------------------------------

    /// A number for HTML: two decimals at most, no trailing zeros.
    static func num(_ v: Double) -> String {
        let v = v == 0 ? 0.0 : v // normalise the signed zero
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s.isEmpty || s == "-" || s == "-0" { return "0" }
        return s
    }

    /// Escape text for HTML content and attribute values.
    static func escapeHTML(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for c in value {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    // -----------------------------------------------------------------------
    // CSS + script (ported from script.rs)
    // -----------------------------------------------------------------------

    static let deckCSS = """
    html,body{margin:0;padding:0;background:transparent;}
    body{overflow-x:hidden;}
    .slide{position:relative;width:calc(var(--dw) * 1pt * var(--zoom,1));height:calc(var(--dh) * 1pt * var(--zoom,1));margin:14px auto;background:#FFFFFF;box-shadow:0 2px 10px rgba(0,0,0,0.28);scroll-snap-align:center;}
    .stage{position:absolute;top:0;left:0;width:calc(var(--dw) * 1pt);height:calc(var(--dh) * 1pt);transform:scale(var(--zoom,1));transform-origin:top left;overflow:hidden;}
    .item{position:absolute;}
    .item > svg.shape{position:absolute;top:0;left:0;width:100%;height:100%;}
    .tb{position:absolute;top:0;left:0;width:100%;height:100%;box-sizing:border-box;display:flex;flex-direction:column;}
    .tb p{margin:0;}
    .blt{margin-right:0.35em;}
    .blt-img{height:0.9em;vertical-align:-0.1em;}
    img.pic{display:block;width:100%;height:100%;}
    .picwrap{position:absolute;top:0;left:0;width:100%;height:100%;overflow:hidden;display:block;}
    .hit{position:absolute;top:0;left:0;width:100%;height:100%;}
    .tblwrap{position:absolute;top:0;left:0;width:100%;height:100%;}
    .tblwrap table{width:100%;height:100%;border-collapse:collapse;}
    .tblwrap td{border:0.75pt solid rgba(0,0,0,0.25);vertical-align:middle;padding:2pt 5pt;overflow:hidden;}
    .frame{position:absolute;top:0;left:0;width:100%;height:100%;box-sizing:border-box;display:flex;align-items:center;justify-content:center;border:1.5pt dashed rgba(0,0,0,0.35);color:rgba(0,0,0,0.55);font-family:sans-serif;}
    .frame img{position:absolute;top:0;left:0;width:100%;height:100%;object-fit:contain;}
    .frame-label{position:relative;background:rgba(255,255,255,0.85);padding:2pt 8pt;font-size:12pt;}
    .sn-speak{background:rgba(255,196,0,0.42) !important;}
    """

    /// The slide script: `window.__snslides` — show, current, fit, highlight —
    /// plus the scroll reporting. The iOS cut of the Linux script: no GTK
    /// device-scale split (WebKit's viewport is the truth here), no
    /// presentation mode yet.
    static let slidesScript = """
    (function () {
        if (window.__snslides) { return; }
        var cfg = { zoom: 1, fit: "width", manual: 1 };

        function fitZoom(mode, manual) {
            var de = document.documentElement;
            var dw = +de.dataset.w || 720, dh = +de.dataset.h || 405;
            if (mode === 'none') { return Math.max(0.05, Math.min(+manual || 1, 8)); }
            var availW = Math.max(window.innerWidth - 28, 120);
            var byW = availW / (dw * 4 / 3);
            if (mode === 'page') {
                var availH = Math.max(window.innerHeight - 28, 90);
                return Math.max(Math.min(byW, availH / (dh * 4 / 3)), 0.05);
            }
            return Math.max(Math.min(byW, 8.0), 0.05);
        }

        function post(msg) {
            try { window.webkit.messageHandlers.snslides.postMessage(msg); } catch (e) {}
        }

        function slides() { return document.querySelectorAll('.slide'); }

        function nearest() {
            var best = 0, dist = Infinity;
            var els = slides();
            for (var i = 0; i < els.length; i++) {
                var r = els[i].getBoundingClientRect();
                var d = Math.abs(r.top + r.height / 2 - window.innerHeight / 2);
                if (d < dist) { dist = d; best = i; }
            }
            return best;
        }

        var reported = -1;
        function report(i) {
            if (i === reported) { return; }
            reported = i;
            post('slidechanged:' + i);
        }

        function show(i) {
            var el = document.getElementById('s' + i);
            if (!el) { return; }
            el.scrollIntoView({ behavior: 'auto', block: 'start' });
            report(i);
        }

        function step(delta) {
            var els = slides();
            var i = nearest() + delta;
            if (i < 0 || i >= els.length) { return; }
            els[i].scrollIntoView({ behavior: 'auto', block: 'start' });
            report(i);
        }

        var scrollTimer = null;
        window.addEventListener('scroll', function () {
            if (scrollTimer) { return; }
            scrollTimer = setTimeout(function () {
                scrollTimer = null;
                report(nearest());
            }, 150);
        }, true);

        // A tap on the page reports chrome: the reader hides its bars while
        // reading (a WKWebView swallows SwiftUI taps, which is why the
        // report comes from here, exactly like the epub shell's chromeTap).
        document.addEventListener('click', function (ev) {
            if (ev.target && ev.target.closest && ev.target.closest('a')) { return; }
            post('chromeTap:0');
        }, true);

        window.__snslides = {
            show: show,
            step: step,
            current: nearest,
            setFit: function (mode, manual) {
                cfg.fit = mode; cfg.manual = +manual || 1;
                cfg.zoom = fitZoom(mode, cfg.manual);
                document.documentElement.style.setProperty('--zoom', cfg.zoom);
            },
            highlight: function (s, e) {
                clearHighlight();
                var els = document.querySelectorAll('[data-s]'), first = null;
                for (var i = 0; i < els.length; i++) {
                    var el = els[i];
                    var ds = +el.getAttribute('data-s'), de = +el.getAttribute('data-e');
                    if (ds < e && de > s) {
                        el.classList.add('sn-speak');
                        if (!first) { first = el; }
                    }
                }
                if (first) { first.scrollIntoView({ behavior: 'smooth', block: 'center' }); }
            },
            clearHighlight: clearHighlight
        };

        function clearHighlight() {
            var els = document.querySelectorAll('.sn-speak');
            for (var i = 0; i < els.length; i++) { els[i].classList.remove('sn-speak'); }
        }
    })();
    """
}

/// A deck from its bytes: format decided by content — an OOXML package goes
/// to the ported reader (a compound file means a legacy .ppt or an encrypted
/// package, neither of which this build reads yet).
public enum DeckParser {
    public static func parse(_ bytes: Data) throws -> SlideDeck {
        if Pptx.isEncrypted(bytes) {
            throw SlideError.encrypted
        }
        if Pptx.sniffs(bytes) {
            let pres = try Pptx.import(bytes)
            return DeckSlides.fromPresentation(pres)
        }
        throw SlideError.notADeck("neither an OOXML package nor an ODF presentation")
    }
}
