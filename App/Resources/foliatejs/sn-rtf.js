// The RTF renderer — RTF → styled HTML, feeding sn-docbook.js.
//
// The old Rust path reduced RTF to paragraphs (bold tracked, then thrown
// away at the text layer); this renderer keeps what RTF actually says, the
// way WordPad or a text editor would show it: bold, italic, underline,
// strike, font sizes, colours, alignment, indents, real tables, and the
// pictures (\pict blips) as images. What RTF has no real TOC for, headings
// are inferred the way the format implies them — a short, fully-bold,
// unpunctuated line standing alone — and each inferred heading starts a new
// section, so the contents sidebar and section progress both work.
//
// The scanner follows the same discipline as the reference reader: groups
// push and pop formatting state, ignorable destinations (\*…) are skipped,
// \ucN sets the \uN fallback count, \'hh bytes decode in the document's
// codepage, and a `\u` escape swallows only its own fallback bytes.

import { buildDocBook } from './sn-docbook.js'

const CODEPAGES = {
    437: 'windows-874', 874: 'windows-874', 932: 'shift_jis', 936: 'gb18030',
    949: 'euc-kr', 950: 'big5', 10000: 'macintosh', 1250: 'windows-1250',
    1251: 'windows-1251', 1252: 'windows-1252', 1253: 'windows-1253',
    1254: 'windows-1254', 1255: 'windows-1255', 1256: 'windows-1256',
    1257: 'windows-1257', 1258: 'windows-1258', 65001: 'utf-8',
}

const DESTINATIONS_TO_SKIP = new Set([
    'fonttbl', 'stylesheet', 'listtable', 'listoverridetable',
    'generator', 'object', 'themedata', 'colorschememapping', 'datastore',
    'xmlnstbl', 'latentstyles', 'rsidtbl', 'mmathPr', 'upr', 'header',
    'headerl', 'headerr', 'footer', 'footerl', 'footerr', 'footnote',
    'ftnsep', 'ftnsepc', 'ftncn', 'aftnsep', 'aftnsepc', 'aftncn', 'pntext',
    'pn', 'pntextb', 'pntexta', 'nonshppict', 'shprslt', 'do', 'shpinst',
    'fontemb', 'filetbl', 'objdata', 'objclass', 'objname', 'result',
])

const ENTITY_WORDS = {
    emdash: '\u2014', endash: '\u2013', lquote: '\u2018', rquote: '\u2019',
    ldblquote: '\u201C', rdblquote: '\u201D', bullet: '\u2022', nbsp: '\u00A0',
    emspace: '\u2003', enspace: '\u2002', qmspace: '\u2005', zwnj: '\u200C',
    zwj: '\u200D', ltrmark: '\u200E', rtlmark: '\u200F', para: '\u00B6',
    tab: ' ',
}

const escapeXml = str => str
    .replace(/[&<>"']/g, ch => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[ch]))

const hexValue = byte =>
    byte >= 0x30 && byte <= 0x39 ? byte - 0x30
    : byte >= 0x41 && byte <= 0x46 ? byte - 0x41 + 10
    : byte >= 0x61 && byte <= 0x66 ? byte - 0x61 + 10 : null

// One paragraph's formatting state. A group pushes a copy and mutations
// inside it pop away with the group.
const newState = () => ({
    bold: false, italic: false, underline: false, strike: false,
    fontSize: null, // half-points
    color: null, background: null, // '#rrggbb'
    align: null, // 'center' | 'right' | 'justify'
    indentLeft: 0, indentRight: 0, spaceBefore: 0, spaceAfter: 0,
    inTable: false, codepage: 1252,
})

const styleOf = state => {
    const css = []
    if (state.fontSize) css.push(`font-size:${state.fontSize / 2}pt`)
    if (state.color) css.push(`color:${state.color}`)
    if (state.background) css.push(`background-color:${state.background}`)
    const style = css.length ? ` style="${css.join(';')}"` : ''
    return { style }
}

const paragraphStyleOf = state => {
    const css = []
    if (state.align) css.push(`text-align:${state.align}`)
    if (state.indentLeft) css.push(`margin-left:${state.indentLeft * 0.125}em`)
    if (state.indentRight) css.push(`margin-right:${state.indentRight * 0.125}em`)
    if (state.spaceBefore) css.push(`margin-top:${state.spaceBefore}pt`)
    if (state.spaceAfter) css.push(`margin-bottom:${state.spaceAfter}pt`)
    return css.length ? ` style="${css.join(';')}"` : ''
}

const headingHeuristic = paragraph => {
    // A short, entirely-emphasised, unpunctuated line standing alone is the
    // RTF corpus's way of writing a heading — the same convention the old
    // parser used, now made visible instead of buried in the text layer.
    // A paragraph's text lives in its runs (picture runs carry none).
    const text = paragraph.runs
        .filter(run => run.picture == null)
        .map(run => run.text).join('').trim()
    if (!text || text.length > 100) return false
    if (/[.!?:;,]$/.test(text)) return false
    const emphasised = paragraph.runs.length > 0 &&
        paragraph.runs.every(run => run.bold)
    return emphasised
}

export function rtfToBook(bytes, { title, author }) {
    const decoderCache = new Map()
    const decodeWith = codepage => {
        const name = CODEPAGES[codepage] ?? 'windows-1252'
        if (!decoderCache.has(name))
            decoderCache.set(name, new TextDecoder(name))
        return decoderCache.get(name)
    }

    // -- parse --------------------------------------------------------------
    const colors = [] // colortbl entries, index 0 is 'auto'
    const paragraphs = [] // { runs: [{text, ...fmt}], state }
    const pictures = [] // { mime, hex } → data URIs, referenced in runs
    const meta = { title, author }
    let state = newState()
    const stateStack = []
    let run = { text: '', bold: false, italic: false, underline: false, strike: false, fontSize: null, color: null, background: null }
    let paragraph = { runs: [], state: null }
    let byteBuffer = [] // \'hh bytes awaiting codepage decode
    let skipDepth = 0 // > 0: inside a skipped destination
    let unicodeFallback = 1
    let picture = null // { mime, hex } while a \pict group is read
    let pictDepth = 0 // nested groups inside the picture ({\*\picprop…})
    let colorTable = null // { r, g, b, any } while \colortbl is read
    let pendingFallbackSkip = 0

    const flushRun = () => {
        if (byteBuffer.length) {
            run.text += decodeWith(state.codepage)
                .decode(new Uint8Array(byteBuffer), { stream: true })
            byteBuffer = []
        }
        if (run.text) paragraph.runs.push(run)
        run = { text: '', bold: state.bold, italic: state.italic,
            underline: state.underline, strike: state.strike,
            fontSize: state.fontSize, color: state.color, background: state.background }
    }

    const flushParagraph = () => {
        flushRun()
        if (paragraph.runs.length) {
            paragraph.state = { ...state }
            paragraphs.push(paragraph)
        }
        paragraph = { runs: [], state: null }
    }

    const openSkip = () => { flushRun(); skipDepth += 1 }

    const apply = (word, param, hasParam) => {
        switch (word) {
            case 'ansicpg':
                if (hasParam) state.codepage = param
                return true
            case 'b': state.bold = !hasParam || param !== 0; return true
            case 'i': state.italic = !hasParam || param !== 0; return true
            case 'ul': case 'ulw': case 'uld': case 'uldb':
                state.underline = !hasParam || param !== 0; return true
            case 'ulnone': state.underline = false; return true
            case 'strike': state.strike = !hasParam || param !== 0; return true
            case 'striked': state.strike = !hasParam || param !== 0; return true
            case 'plain':
                state.bold = state.italic = state.underline = state.strike = false
                state.fontSize = null; state.color = null; state.background = null
                return true
            case 'fs':
                if (hasParam) state.fontSize = param
                return true
            case 'cf':
                if (hasParam && colors[param]) state.color = colors[param]
                return true
            case 'cb': case 'highlight':
                if (hasParam && colors[param]) state.background = colors[param]
                return true
            case 'qc': state.align = 'center'; return true
            case 'qr': state.align = 'right'; return true
            case 'qj': state.align = 'justify'; return true
            case 'ql': state.align = null; return true
            case 'li': if (hasParam) state.indentLeft = param; return true
            case 'ri': if (hasParam) state.indentRight = param; return true
            case 'sb': if (hasParam) state.spaceBefore = param; return true
            case 'sa': if (hasParam) state.spaceAfter = param; return true
            case 'intbl': state.inTable = true; return true
            case 'pard':
                state.align = null
                state.indentLeft = state.indentRight = 0
                state.spaceBefore = state.spaceAfter = 0
                state.inTable = false
                return true
            case 'par': case 'sect': case 'page': flushParagraph(); return true
            case 'line': flushRun(); run.text += '<br/>'; return true
            case 'tab': flushRun(); run.text += '\t'; return true
            case 'cell':
                // Word's cell separator: a visible boundary. A real table
                // needs \trowd geometry; without it the cells read as a
                // paragraph with cell gaps — the old reader's ", " joins,
                // now visible.
                flushRun(); run.text += '\u2003'; return true
            case 'row': flushParagraph(); return true
            case 'u': {
                if (!hasParam) return true
                const scalar = (param < 0 ? param + 65536 : param)
                const c = scalar > 0xFFFF ? '' : String.fromCharCode(scalar)
                flushRun()
                run.text += c
                // Swallow up to \ucN bytes of the ANSI fallback the writer
                // emitted; stop at syntax so a runaway fallback can't eat
                // the document. The scanner reads this pending count.
                pendingFallbackSkip = Math.max(0, unicodeFallback)
                return true
            }
            case 'uc':
                if (hasParam) unicodeFallback = Math.max(0, param)
                return true
            case 'ucd': return true
            case 'emdash': case 'endash': case 'lquote': case 'rquote':
            case 'ldblquote': case 'rdblquote': case 'bullet': case 'nbsp':
            case 'emspace': case 'enspace': case 'qmspace': case 'zwnj':
            case 'zwj': case 'ltrmark': case 'rtlmark': case 'para':
                flushRun(); run.text += ENTITY_WORDS[word]; return true
            case 'deff0': case 'defformat': case 'deflang': return true
            case 'title': case 'author': case 'subject': case 'keywords':
            case 'operator': case 'company': case 'category': case 'doccomm':
                if (skipDepth > 0) { meta[word === 'title' ? 'title' : word === 'author' ? 'author' : null] ??= null; state.infoKey = word }
                return true
            case 'info': openSkip(); return true
            case 'pngblip': if (picture) picture.mime = 'image/png'; return true
            case 'jpegblip': if (picture) picture.mime = 'image/jpeg'; return true
            case 'emfblip': case 'wmetafile':
                if (picture) picture.mime = null // unreadable in a browser
                return true
            default:
                return false
        }
    }

    // The scanner: a single pass over the bytes.
    let i = 0
    const n = bytes.length
    while (i < n) {
        const byte = bytes[i]

        if (colorTable) {
            // {\colortbl ;\redN\greenN\blueN;…} — entries separated by ';',
            // the first (empty) one being the 'auto' colour.
            if (byte === 0x7d) { // }
                if (colorTable.any)
                    colors.push(colorTable.r != null
                        ? `rgb(${colorTable.r},${colorTable.g},${colorTable.b})`
                        : 'auto')
                colorTable = null
                if (stateStack.length) state = stateStack.pop()
                i += 1
                continue
            }
            if (byte === 0x3b) { // ;
                colors.push(colorTable.any && colorTable.r != null
                    ? `rgb(${colorTable.r},${colorTable.g},${colorTable.b})`
                    : 'auto')
                colorTable = { r: null, g: null, b: null, any: false }
                i += 1
                continue
            }
            if (byte === 0x5c) { // \redN \greenN \blueN
                let j = i + 1
                let word = ''
                while (j < n && ((bytes[j] >= 0x41 && bytes[j] <= 0x5a) ||
                    (bytes[j] >= 0x61 && bytes[j] <= 0x7a))) {
                    word += String.fromCharCode(bytes[j]); j += 1
                }
                let paramStr = ''
                while (j < n && bytes[j] >= 0x30 && bytes[j] <= 0x39) {
                    paramStr += String.fromCharCode(bytes[j]); j += 1
                }
                const value = parseInt(paramStr, 10)
                if (word === 'red') { colorTable.r = value; colorTable.any = true }
                if (word === 'green') { colorTable.g = value; colorTable.any = true }
                if (word === 'blue') { colorTable.b = value; colorTable.any = true }
                i = j
                continue
            }
            i += 1
            continue
        }

        if (skipDepth > 0) {
            // While skipping, only group syntax matters; the info group's
            // text is captured for metadata. Nested braces COUNT: skipDepth
            // tracks the skipped destination's own group, so a nested
            // group's close cannot end the skip early (a Word fonttbl or
            // \picprop carries many — without the count, the font names and
            // the picture payload pour into the text).
            if (byte === 0x7b) { // {
                stateStack.push({ ...state })
                skipDepth += 1
                i += 1
            } else if (byte === 0x7d) { // }
                skipDepth = Math.max(0, skipDepth - 1)
                if (state.infoKey) {
                    const key = state.infoKey === 'title' ? 'title'
                        : state.infoKey === 'author' ? 'author' : null
                    const text = (state.infoText ?? '').trim()
                    if (key && text && !meta[key]) meta[key] = text
                    state.infoKey = null
                    state.infoText = ''
                }
                if (stateStack.length) state = stateStack.pop()
                i += 1
            } else if (byte === 0x5c) { // backslash
                const next = bytes[i + 1]
                if (next === 0x27) { // \'hh — metadata text
                    const hi = hexValue(bytes[i + 2])
                    const lo = hexValue(bytes[i + 3])
                    if (hi != null && lo != null) {
                        if (state.infoKey)
                            state.infoText += decodeWith(state.codepage)
                                .decode(new Uint8Array([hi * 16 + lo]), { stream: true })
                    }
                    i += 4
                } else {
                    // A control word inside a skipped group may OPEN another
                    // skip (a nested destination) — parse it as a word.
                    let j = i + 1
                    if (next === 0x2a) j += 1 // \*
                    let word = ''
                    while (j < n && ((bytes[j] >= 0x41 && bytes[j] <= 0x5a) ||
                        (bytes[j] >= 0x61 && bytes[j] <= 0x7a))) {
                        word += String.fromCharCode(bytes[j]); j += 1
                    }
                    let param = ''
                    let hasDash = false
                    if (j < n && bytes[j] === 0x2d) { hasDash = true; j += 1 }
                    while (j < n && bytes[j] >= 0x30 && bytes[j] <= 0x39) {
                        param += String.fromCharCode(bytes[j]); j += 1
                    }
                    if (word === 'pict' || DESTINATIONS_TO_SKIP.has(word) ||
                        (word === '' && next === 0x2a)) {
                        // pict inside skip: still skipped; nothing to do —
                        // its braces already counted at the group's open.
                    }
                    i = j + (word === '' && param === '' && !hasDash ? 1 : 0)
                }
            } else if (byte === 0x0d || byte === 0x0a) {
                i += 1
            } else {
                if (state.infoKey)
                    state.infoText += String.fromCharCode(byte)
                i += 1
            }
            continue
        }

        if (picture) {
            // Inside a \pict group: hex bytes accumulate until the group
            // ends. Nested groups count — a Word picture opens
            // {\*\picprop{\sp…}{\sp…}} before its data, and the first
            // nested `}` must close only that group, not the picture.
            if (byte === 0x7b) { // {
                pictDepth += 1
                i += 1
                continue
            }
            if (byte === 0x7d) { // }
                if (pictDepth > 0) {
                    pictDepth -= 1
                    i += 1
                    continue
                }
                if (picture.hex.length && picture.mime) {
                    pictures.push(picture)
                    flushParagraph()
                    paragraph.runs.push({
                        text: `__SN_PICTURE_${pictures.length - 1}__`,
                        picture: pictures.length - 1,
                        bold: false, italic: false, underline: false, strike: false,
                        fontSize: null, color: null, background: null,
                    })
                }
                picture = null
                if (stateStack.length) state = stateStack.pop()
                i += 1
                continue
            }
            if (byte === 0x5c) {
                // A control word inside the picture (\pngblip, \jpegblip, \binN…)
                let j = i + 1
                if (bytes[j] === 0x2a) j += 1
                let word = ''
                while (j < n && ((bytes[j] >= 0x41 && bytes[j] <= 0x5a) ||
                    (bytes[j] >= 0x61 && bytes[j] <= 0x7a))) {
                    word += String.fromCharCode(bytes[j]); j += 1
                }
                let param = ''
                if (j < n && bytes[j] === 0x2d) j += 1
                while (j < n && bytes[j] >= 0x30 && bytes[j] <= 0x39) {
                    param += String.fromCharCode(bytes[j]); j += 1
                }
                apply(word, parseInt(param, 10), param !== '')
                // \binN: the next N bytes are the (binary) picture data.
                if (word === 'bin' && param !== '') {
                    const count = parseInt(param, 10)
                    for (let k = 0; k < count && j < n; k++, j++) {
                        picture.hex += bytes[j].toString(16).padStart(2, '0')
                    }
                }
                i = j
                continue
            }
            const hv = hexValue(byte)
            if (hv != null) picture.hex += hv.toString(16)
            i += 1
            continue
        }

        switch (byte) {
            case 0x7b: // {
                flushRun()
                stateStack.push({ ...state })
                i += 1
                break
            case 0x7d: // }
                flushRun()
                if (state.infoKey) {
                    const key = state.infoKey === 'title' ? 'title'
                        : state.infoKey === 'author' ? 'author' : null
                    const text = (state.infoText ?? '').trim()
                    if (key && text && !meta[key]) meta[key] = text
                    state.infoKey = null
                    state.infoText = ''
                }
                if (stateStack.length) state = stateStack.pop()
                i += 1
                break
            case 0x5c: { // backslash
                let j = i + 1
                const next = bytes[j]
                if (next === 0x27) { // \'hh
                    const hi = hexValue(bytes[j + 1])
                    const lo = hexValue(bytes[j + 2])
                    if (hi != null && lo != null) byteBuffer.push(hi * 16 + lo)
                    i = j + 3
                    break
                }
                if (next === 0x2a) { // \*\<word> — an ignorable destination
                    let k = j + 1
                    // The destination word carries its own backslash:
                    // `\*\revtbl` — without stepping over it, the word
                    // parses empty and no destination ever skips (the
                    // revision table's "Unknown;" and the list markers
                    // then pour into the text).
                    if (bytes[k] === 0x5c) k += 1
                    let word = ''
                    while (k < n && ((bytes[k] >= 0x41 && bytes[k] <= 0x5a) ||
                        (bytes[k] >= 0x61 && bytes[k] <= 0x7a))) {
                        word += String.fromCharCode(bytes[k]); k += 1
                    }
                    if (word === 'pict') {
                        flushRun()
                        picture = { mime: null, hex: '' }
                        pictDepth = 0
                        i = k
                        break
                    }
                    if (word === 'shppict') {
                        // The modern picture wrapper: transparent — its
                        // inner \pict is the one this reader renders. (The
                        // old-reader copy, \nonshppict, is what gets
                        // skipped, so the picture renders once.)
                        i = k
                        break
                    }
                    if (DESTINATIONS_TO_SKIP.has(word) || word) {
                        // An unknown ignorable destination: skip its group.
                        openSkip()
                        i = k
                        break
                    }
                    i = j + 1
                    break
                }
                let word = ''
                while (j < n && ((bytes[j] >= 0x41 && bytes[j] <= 0x5a) ||
                    (bytes[j] >= 0x61 && bytes[j] <= 0x7a))) {
                    word += String.fromCharCode(bytes[j]); j += 1
                }
                let hasDash = false
                if (j < n && bytes[j] === 0x2d) { hasDash = true; j += 1 }
                let paramStr = ''
                while (j < n && bytes[j] >= 0x30 && bytes[j] <= 0x39) {
                    paramStr += String.fromCharCode(bytes[j]); j += 1
                }
                const hasParam = paramStr !== '' || hasDash
                const param = hasParam
                    ? (hasDash ? -1 : 1) * (parseInt(paramStr, 10) || 0)
                    : 0
                // A control word delimiter: space (consumed) or any other.
                if (bytes[j] === 0x20) j += 1

                if (word === 'pict') {
                    flushRun()
                    picture = { mime: null, hex: '' }
                    pictDepth = 0
                    i = j
                    break
                }
                if (word === 'colortbl') {
                    flushRun()
                    stateStack.push({ ...state })
                    colorTable = { r: null, g: null, b: null, any: false }
                    i = j
                    break
                }
                if (DESTINATIONS_TO_SKIP.has(word)) {
                    openSkip()
                    i = j
                    break
                }
                apply(word, param, hasParam)
                i = j
                break
            }
            case 0x0d: case 0x0a:
                i += 1
                break
            default: {
                if (pendingFallbackSkip > 0) {
                    // The \u escape's ANSI fallback bytes: not text. A syntax
                    // byte ends the fallback and is handled on the next pass.
                    if (byte === 0x5c || byte === 0x7b || byte === 0x7d) {
                        pendingFallbackSkip = 0
                        continue
                    }
                    pendingFallbackSkip -= 1
                    i += 1
                    break
                }
                if (byte < 0x80) {
                    // ASCII: codepage bytes already buffered decode first,
                    // so a mixed run keeps its order.
                    if (byteBuffer.length) {
                        run.text += decodeWith(state.codepage)
                            .decode(new Uint8Array(byteBuffer), { stream: true })
                        byteBuffer = []
                    }
                    run.text += String.fromCharCode(byte)
                } else {
                    byteBuffer.push(byte)
                }
                i += 1
                break
            }
        }
    }
    flushParagraph()

    // -- compose HTML ---------------------------------------------------------
    const pictureUrls = pictures.map((p, idx) => {
        if (!p.mime) return null
        return `data:${p.mime};base64,` + btoa(/** hex→binary */
            Array.from({ length: p.hex.length / 2 }, (_, k) =>
                String.fromCharCode(parseInt(p.hex.slice(k * 2, k * 2 + 2), 16))).join(''))
    })

    const blocks = []
    for (const para of paragraphs) {
        const inner = para.runs.map(r => {
            if (r.picture != null) {
                const url = pictureUrls[r.picture]
                return url ? `<img src="${url}" alt=""/>` : ''
            }
            const tags = []
            if (r.bold) tags.push('b')
            if (r.italic) tags.push('i')
            if (r.underline) tags.push('u')
            if (r.strike) tags.push('s')
            const { style } = styleOf({
                fontSize: r.fontSize, color: r.color, background: r.background,
            })
            let body = escapeXml(r.text).replace(/\t/g, '\u2003\u2003')
            for (const tag of tags) body = `<${tag}>${body}</${tag}>`
            return style ? `<span${style}>${body}</span>` : body
        }).join('')
        const text = para.runs.filter(r => r.picture == null)
            .map(r => r.text).join('').trim()
        if (!text && !para.runs.some(r => r.picture != null)) {
            blocks.push('') // an empty paragraph — spacing only
            continue
        }
        if (headingHeuristic(para) && text) {
            blocks.push(`<h3>${inner}</h3>`)
        } else {
            const style = paragraphStyleOf(para.state ?? state)
            blocks.push(`<p${style}>${inner || '\u00A0'}</p>`)
        }
    }

    // Sections: each inferred heading starts one; content before the first
    // heading is the preamble section.
    const chapters = []
    let current = { title: null, html: '' }
    let toc = []
    for (const block of blocks) {
        if (block.startsWith('<h3>')) {
            if (current.html.trim()) chapters.push(current)
            const label = block.replace(/^<h3>|<\/h3>$/g, '')
                .replace(/<[^>]+>/g, '').trim()
            current = { title: label, html: block }
            toc.push({ label, index: chapters.length, anchorId: null, subitems: [] })
        } else {
            current.html += block
        }
    }
    if (current.html.trim()) chapters.push(current)
    if (chapters.length === 0) chapters.push({ title: null, html: '<p></p>' })

    const book = buildDocBook(chapters, toc, {
        title: meta.title || title,
        author: meta.author || author || '',
        language: undefined,
    })
    return book
}
