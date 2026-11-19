// The book shell for the headless document family (.mobi/.azw/.azw3/.prc/
// .pdb/.fb2/.rtf/.html/.htmlz/.txt/.md): a port of the Linux reader's
// sn-ui/assets/foliate-js/sn-shell.js onto the iOS bridge. The vendored
// foliate modules (readest's fork, MIT — see foliatejs/LICENSE) parse the
// book's ORIGINAL file right here in the webview — the Mobipocket family
// through mobi.js (its JS decompressors are the reason the letters stop
// repeating), .fb2 through fb2.js, .rtf through the RTF renderer, .html
// through the HTML book builder, .txt/.md through the chapteriser. Nothing
// is converted to EPUB and nothing is pre-parsed on the native side: the
// reader and the importer consume the same bytes the user opened.
//
// Two modes off one module, picked by the `mode` query item:
//
// * reader (default) — boots a `foliate-view`, applies the reader's type
//   layer per loaded section, and bridges the view's events to SwiftUI
//   through the `reader` message channel as OBJECTS ({type: "relocated",
//   …}), the exact protocol the epub.js shell (reader.js) speaks — so
//   BookReaderView drives both shells with the same commands and hears the
//   same messages. Commands: readerGoChapter / readerNext / readerPrev /
//   readerAppearance / readerGoToHref / readerAutoScroll / … (the
//   BookWebView command surface), which land on view.goTo/next/prev —
//   in-renderer navigation, no page reload, which is why a chapter jump
//   lands immediately.
// * parse — the importer's headless boot (DocumentParseService): no view,
//   just the parsed book exposed on window.__snParse for Swift to pull
//   (metadata, resolved TOC, per-section XHTML, cover). The per-section
//   XHTML is what lands in doc/chapter-N.html as the TTS text source —
//   the same chaptering the reader shows, so TTS chapter indexes and
//   reader section indexes can never drift apart.
//
// The dispatch mirrors the Linux shell's (readest's DocumentLoader.open()):
// a .txt/.md goes through the chapteriser, .html/.htmlz through the HTML
// book builder, .rtf through the RTF renderer, .fb2 through fb2.js, the
// Mobipocket/Kindle family through mobi.js.

import { View } from './view.js'
import { txtToChapters } from './sn-txt.js'
import { buildDocBook } from './sn-docbook.js'
import { htmlToBook, htmlzToBook } from './sn-html.js'
import { rtfToBook } from './sn-rtf.js'

const say = (...parts) => { try { console.log('[sn-shell]', ...parts) } catch {} }
say('module loaded')

// The iOS bridge: object messages on the `reader` channel — the same
// channel name and message shapes the epub.js shell uses, so BookWebView's
// one handler serves both.
const post = msg => {
    try { window.webkit.messageHandlers.reader.postMessage(msg) } catch (e) {}
}
const error = message => post({ type: 'error', message: String(message ?? 'unknown') })

const params = new URLSearchParams(location.search)
const bookUrl = params.get('src')
const format = (params.get('format') ?? '').toLowerCase()
const mode = (params.get('mode') ?? 'reader').toLowerCase()

// -- format dispatch (the Linux shell's, minus the containers the epub.js
//    shell owns — an .epub never reaches this page) ------------------------

const zipLoader = async bytes => {
    const { configure, ZipReader, BlobReader, TextWriter, BlobWriter } =
        await import('./vendor/zip.js')
    configure({ useWebWorkers: false })
    const reader = new ZipReader(new BlobReader(new Blob([bytes])))
    const entries = await reader.getEntries()
    const map = new Map(entries.map(entry => [entry.filename, entry]))
    const load = f => (name, ...args) =>
        map.has(name) ? f(map.get(name), ...args) : null
    return {
        entries,
        loadText: load(entry => entry.getData(new TextWriter())),
        loadBlob: load((entry, type) => entry.getData(new BlobWriter(type))),
        getSize: name => map.get(name)?.uncompressedSize ?? 0,
    }
}

const openMobi = async bytes => {
    const { isMOBI, MOBI } = await import('./mobi.js')
    const file = new Blob([bytes])
    if (!await isMOBI(file))
        throw new Error('not a Mobipocket book — the .pdb extension is shared ' +
            'with other Palm-era formats this reader cannot open')
    const fflate = await import('./vendor/fflate.js')
    return new MOBI({ unzlib: fflate.unzlibSync }).open(file)
}

const openFb2 = async bytes => {
    const { makeFB2 } = await import('./fb2.js')
    return makeFB2(new Blob([bytes]))
}

const openTxt = async bytes => {
    const { chapters, language } = txtToChapters(bytes)
    if (!chapters.length) throw new Error('the file has no readable text')
    return buildDocBook(chapters, chapters
        .filter(c => c.title)
        .map(c => ({
            label: c.title,
            index: chapters.indexOf(c),
            anchorId: null,
            subitems: [],
        })), {
        title: params.get('title') ?? '',
        author: params.get('author') ?? '',
        language,
    })
}

const openHtml = bytes => htmlToBook(bytes, {
    title: params.get('title') ?? '',
    author: params.get('author') ?? '',
})

const openHtmlz = async bytes => {
    const zipMod = await import('./vendor/zip.js')
    return htmlzToBook(bytes, zipMod, {
        title: params.get('title') ?? '',
        author: params.get('author') ?? '',
    })
}

const openRtf = bytes => rtfToBook(bytes, {
    title: params.get('title') ?? '',
    author: params.get('author') ?? '',
})

const openFile = async bytes => {
    switch (format) {
        case 'txt': case 'text': case 'md': case 'markdown': return openTxt(bytes)
        case 'rtf': return openRtf(bytes)
        case 'html': case 'htm': return openHtml(bytes)
        case 'htmlz': return openHtmlz(bytes)
        case 'fb2': return openFb2(bytes)
        case 'mobi': case 'azw': case 'azw3': case 'prc': case 'pdb':
            return openMobi(bytes)
        default:
            throw new Error(`this reader cannot open .${format} files`)
    }
}

// -- shared helpers ----------------------------------------------------------

// Chapter titles arrive XML-escaped (they were written into XHTML); the
// sidebar renders plain text, so the five entities come back out here.
const unescapeXml = str => str
    .replace(/&(amp|lt|gt|quot|#39);/g, (_, ent) => ({
        amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'",
    }[ent]))

const resolveIndex = async (book, href) => {
    if (!book) return 0
    try {
        const resolved = await book.resolveHref(href)
        return resolved?.index ?? 0
    } catch {
        return 0
    }
}

// Each contents row carries the section it lands on, resolved through the
// book's own href table — mobi.js resolves asynchronously (KF8 sections
// decompress on demand); await normalises sync and async resolvers alike.
const flattenToc = async (book, items, depth) => Promise.all(items.map(async item => ({
    label: unescapeXml(item.label ?? ''),
    href: item.href ?? '',
    index: await resolveIndex(book, item.href ?? ''),
    depth,
    subitems: item.subitems?.length ? await flattenToc(book, item.subitems, depth + 1) : [],
})))

// A loaded section document: strip the scripts and script-bearing
// attributes the book carried (the paginator's iframe sandbox allows
// scripts because of a WebKit bug that renders the sandbox useless without
// it), and serialize — the importer's per-chapter XHTML.
const cleanSectionDoc = doc => {
    for (const script of Array.from(doc.querySelectorAll('script'))) script.remove()
    for (const el of Array.from(doc.querySelectorAll('*'))) {
        for (const attr of Array.from(el.attributes ?? [])) {
            if (/^on/i.test(attr.name)) el.removeAttribute(attr.name)
        }
    }
    return doc
}

const serializeSection = doc =>
    new XMLSerializer().serializeToString(cleanSectionDoc(doc))

const blobToBase64 = blob => new Promise(resolve => {
    if (!blob) { resolve(null); return }
    const reader = new FileReader()
    reader.onload = () => {
        // "data:…;base64,XXXX" — Swift wants the payload alone.
        const s = String(reader.result ?? '')
        resolve(s.includes(',') ? s.slice(s.indexOf(',') + 1) : null)
    }
    reader.onerror = () => resolve(null)
    reader.readAsDataURL(blob)
})

// -- parse mode: the importer's headless boot --------------------------------
// Swift drives one section at a time and waits for the message each step
// posts when done: evaluateJavaScript cannot await a Promise, so the
// result of an async step is stashed and handed over synchronously —
// `prepareSection(i)` posts `parseSection` when the string is ready, and
// `takeSection()` hands it over and drops it (RAM hygiene: one section in
// the JS heap at a time). The cover, small enough for one message body,
// arrives whole on `parseCover`.

const bootParse = async () => {
    const res = await fetch(bookUrl)
    if (!res.ok) throw new Error(`the book's bytes could not be read (${res.status})`)
    const bytes = new Uint8Array(await res.arrayBuffer())
    say('parse: fetched', bytes.length, 'bytes')

    const book = await openFile(bytes)
    say('parse: book built,', book?.sections?.length, 'sections')

    const toc = await flattenToc(book, book.toc ?? [], 0)
    const author = typeof book.metadata?.author === 'string'
        ? book.metadata.author
        : Array.isArray(book.metadata?.author)
            ? book.metadata.author.map(a =>
                typeof a === 'string' ? a : a?.name ?? '').join(', ')
            : ''
    window.__snParse = {
        meta: () => JSON.stringify({
            title: typeof book.metadata?.title === 'string' ? book.metadata.title : '',
            author,
            language: book.metadata?.language ?? '',
            sectionCount: book.sections.length,
            toc,
        }),
        _section: null,
        prepareSection: async index => {
            try {
                const section = book.sections[index]
                if (!section) throw new Error(`no section ${index}`)
                const doc = await section.createDocument()
                window.__snParse._section = serializeSection(doc)
                post({ type: 'parseSection', index, ok: true })
            } catch (e) {
                window.__snParse._section = null
                post({ type: 'parseSection', index, ok: false,
                    message: String(e?.message ?? e) })
            }
        },
        takeSection: () => {
            const s = window.__snParse._section
            window.__snParse._section = null
            return s
        },
        prepareCover: async () => {
            let b64 = null
            try {
                if (book.getCover) b64 = await blobToBase64(await book.getCover())
            } catch (e) {
                say('parse: cover failed', e?.message ?? e)
            }
            post({ type: 'parseCover', b64 })
        },
        destroy: () => {
            try { book.destroy?.() } catch (e) {}
        },
    }
    post({ type: 'parseReady' })
}

// -- reader mode: the foliate-view boot --------------------------------------

let view = null

// The appearance state — the query params are ReaderAppearance.queryItems'
// exact names (the epub shell's set), and readerAppearance({...}) pushes
// the same struct as JSON later.
const THEMES = {
    light: { background: '#ffffff', color: '#1a1a1a' },
    sepia: { background: '#f6efe2', color: '#3b3128' },
    dark: { background: '#121212', color: '#d8d4cf' },
    trueBlack: { background: '#000000', color: '#c9c9c9' },
    eink: { background: '#ffffff', color: '#000000' }
}
const FONTS = {
    serif: 'Georgia, "Iowan Old Style", "Palatino", serif',
    sans: '-apple-system, "Helvetica Neue", Arial, sans-serif',
    mono: '"SF Mono", Menlo, Consolas, monospace'
}

const appearance = {
    theme: params.get('theme') || 'light',
    fontSize: parseInt(params.get('fontSize') || '100', 10),
    flow: params.get('flow') || 'scrolled',
    font: params.get('font') || 'book',
    lineHeight: parseFloat(params.get('lineHeight') || '1.6'),
    paraSpacing: parseFloat(params.get('paraSpacing') || '0'),
    letterSpacing: parseFloat(params.get('letterSpacing') || '0'),
    padding: parseInt(params.get('padding') || '16', 10),
    respectStyles: params.get('respectStyles') === '1',
    tapTurn: params.get('tapTurn') !== '0',
    swipeTurn: params.get('swipeTurn') !== '0',
    tapInverted: params.get('tapInv') === '1',
}

// The reader's type layer, applied per loaded section document — the Linux
// shell's applyTypeLayer with the iOS shell's color rule: theme colors land
// ALWAYS (the epub shell's behavior — a dark theme must darken a respected
// book too), typography only when the book's own styles are not respected.
const applyTypeLayer = doc => {
    const de = doc.documentElement
    const colors = THEMES[appearance.theme] || THEMES.light
    de.style.setProperty('--sn-bg', colors.background)
    de.style.setProperty('--sn-fg', colors.color)
    de.style.backgroundColor = 'var(--sn-bg)'
    de.style.color = 'var(--sn-fg)'
    const body = doc.body
    if (body) {
        body.style.backgroundColor = 'transparent'
        body.style.color = 'var(--sn-fg)'
    }
    if (appearance.respectStyles) {
        // Only colors apply — undo any layer the section carried in from a
        // previous non-respect pass (a flow switch re-renders docs).
        de.style.removeProperty('font-size')
        de.style.removeProperty('letter-spacing')
        const ss = doc.getElementById('sn-viewer-style')
        if (ss) ss.remove()
        return
    }
    // The base size sits on the document element so the section's own em
    // sizes scale with it (calibre's mechanism). The reader's percent maps
    // onto epub.js's 16px base.
    de.style.fontSize = `${Math.round(16 * appearance.fontSize / 100)}px`
    if (appearance.letterSpacing > 0)
        de.style.letterSpacing = `${appearance.letterSpacing}px`
    const styleId = 'sn-viewer-style'
    let ss = doc.getElementById(styleId)
    if (!ss) {
        ss = doc.createElement('style')
        ss.id = styleId
        ;(doc.head ?? de).appendChild(ss)
    }
    const css = []
    if (FONTS[appearance.font])
        css.push(`body{font-family:${FONTS[appearance.font]} !important;}`)
    css.push(`body{line-height:${appearance.lineHeight} !important;}`)
    if (appearance.paraSpacing > 0)
        css.push(`body p{margin-bottom:${appearance.paraSpacing}em !important;}`)
    // Converted books carry wide tables that clip at the page edge — the
    // epub shell's responsive-table treatment: a table pans horizontally.
    css.push('table{display:block;width:fit-content;max-width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch;}')
    css.push('table table{display:table;width:auto;max-width:none;overflow:visible;}')
    ss.textContent = css.join('\n')
}

// The paginator's knobs the view exposes as attributes. `no-continuous-scroll`
// is the Linux reader's setting (each section scrolls its own iframe — the
// scroll evidence the auto-scroll loop relies on); `no-background` stands the
// paginator's own page down so the themed ground reads as one sheet.
const applyRendererAttributes = () => {
    if (!view?.renderer) return
    const flow = appearance.flow === 'paginated' ? 'paginated' : 'scrolled'
    if (view.renderer.getAttribute('flow') !== flow)
        view.renderer.setAttribute('flow', flow)
    view.renderer.setAttribute('margin-top', String(appearance.padding))
    view.renderer.setAttribute('margin-bottom', String(appearance.padding))
    view.renderer.setAttribute('margin-left', String(appearance.padding))
    view.renderer.setAttribute('margin-right', String(appearance.padding))
}

const applyShellGround = () => {
    const colors = THEMES[appearance.theme] || THEMES.light
    const dark = appearance.theme === 'dark' || appearance.theme === 'trueBlack'
    document.documentElement.classList.toggle('sn-dark', dark)
    document.documentElement.style.setProperty('--sn-bg', colors.background)
    document.documentElement.style.backgroundColor = colors.background
}

// The shell's own chapter/position params — a saved resume lands here (the
// manifest's chapter index + the chapter's scroll fraction from the last
// session, or a real foliate CFI from this engine's own relocations).
const resumeCfi = params.get('cfi') ?? ''
const resumeChapter = parseInt(params.get('chapter') || '0', 10)
const resumeFraction = parseFloat(params.get('fraction') || '0')

// Where the primary section's document lives — the iframe the paginator
// currently shows. Auto-scroll and the gestures that need a scroll read go
// through it.
const primaryDoc = () =>
    view?.renderer?.getContents?.()
        .find(x => x.index === view.renderer.primaryIndex)?.doc

// Auto-scroll — the epub shell's hands-free loop, scrolled flow only:
// rAF-driven scroll of the primary section document; at its bottom it steps
// to the next section with a dwell guard so tiny chapters don't fast-forward.
const AUTO = { on: false, speed: 40, last: 0, raf: 0, lastAdvance: 0 }
const stopAutoScroll = () => {
    AUTO.on = false
    if (AUTO.raf) cancelAnimationFrame(AUTO.raf)
    AUTO.raf = 0
    AUTO.last = 0
}
const autoScrollFrame = ts => {
    if (!AUTO.on) return
    if (AUTO.last) {
        const dt = Math.min((ts - AUTO.last) / 1000, 0.1)
        const doc = primaryDoc()
        const win = doc?.defaultView
        if (!win) { AUTO.last = ts; AUTO.raf = requestAnimationFrame(autoScrollFrame); return }
        const max = Math.max(0, (doc.documentElement.scrollHeight || 0) - (win.innerHeight || 0))
        const y = win.scrollY || 0
        if (max <= 4 || y >= max - 2) {
            const now = performance.now()
            if (now - AUTO.lastAdvance < 800) { /* dwell */ } else if (
                view?.book?.sections?.length && view.renderer.primaryIndex
                    >= view.book.sections.length - 1) {
                stopAutoScroll()
                return
            } else {
                AUTO.lastAdvance = now
                view?.next()
            }
        } else {
            win.scrollBy({ top: AUTO.speed * dt, behavior: 'auto' })
        }
    }
    AUTO.last = ts
    AUTO.raf = requestAnimationFrame(autoScrollFrame)
}

const startAutoScroll = () => {
    if (appearance.flow === 'paginated') return
    if (AUTO.on) return
    AUTO.on = true
    AUTO.last = 0
    AUTO.raf = requestAnimationFrame(autoScrollFrame)
}

// A loaded section document: dress it (type layer), and attach the
// per-document listeners — neither scroll nor click nor selection crosses
// the iframe boundary, so a top-document listener never hears them.
const onSectionLoad = ({ doc, index }) => {
    cleanSectionDoc(doc)
    applyTypeLayer(doc)

    const win = doc.defaultView
    if (!win) return

    // Taps: in paginated flow the left/right thirds turn pages and the
    // middle toggles chrome; in scrolled flow any tap (that is not a link
    // or a live selection) toggles chrome. The turn itself posts like the
    // epub shell's iframe relay — SwiftUI evaluates readerNext/readerPrev
    // back here, which fires the haptic and lands on the view in one step.
    doc.addEventListener('click', event => {
        const a = event.target && event.target.closest ? event.target.closest('a') : null
        if (a) return
        const sel = win.getSelection?.()
        if (sel && !sel.isCollapsed && String(sel).length > 0) return
        if (appearance.flow === 'paginated' && appearance.tapTurn) {
            const width = (doc.documentElement && doc.documentElement.clientWidth)
                || (doc.body && doc.body.clientWidth) || 0
            if (width > 0) {
                const x = event.clientX
                const leftZone = x < width / 3
                const rightZone = x > (width * 2) / 3
                if (leftZone || rightZone) {
                    const forward = appearance.tapInverted ? leftZone : rightZone
                    post({ type: 'pageTurn', dir: forward ? 'next' : 'prev' })
                    return
                }
            }
        }
        post({ type: 'chromeTap' })
    }, false)

    // Swipes turn pages in paginated flow (the epub shell's gesture rules:
    // 60 px horizontal, under 600 ms, not on a panning table).
    const touch = { x: 0, y: 0, t: 0, onTable: false }
    const touchStartsOnTable = node => {
        while (node && node !== doc) {
            if (node.tagName === 'TABLE') return true
            node = node.parentElement
        }
        return false
    }
    doc.addEventListener('touchstart', event => {
        const t = event.changedTouches[0]
        if (t) {
            touch.x = t.clientX; touch.y = t.clientY; touch.t = Date.now()
            touch.onTable = touchStartsOnTable(t.target)
        }
    }, { passive: true })
    doc.addEventListener('touchend', event => {
        if (appearance.flow !== 'paginated') return
        if (touch.onTable) return
        if (!appearance.swipeTurn) return
        const t = event.changedTouches[0]
        if (!t) return
        const dx = t.clientX - touch.x
        const dy = t.clientY - touch.y
        if (Date.now() - touch.t > 600) return
        if (Math.abs(dx) < 60 || Math.abs(dy) > 50) return
        const sel = win.getSelection?.()
        if (sel && !sel.isCollapsed && String(sel).length > 0) return
        post({ type: 'pageTurn', dir: dx < 0 ? 'next' : 'prev' })
    }, { passive: true })

    say('section loaded', index)
}

const bootReader = async () => {
    say('boot', bookUrl, 'format', format)
    // The shell's ground follows the theme from the first paint — before the
    // book opens, not after, so a dark theme never flashes white.
    applyShellGround()
    const res = await fetch(bookUrl)
    if (!res.ok) throw new Error(`the book's bytes could not be read (${res.status})`)
    const bytes = new Uint8Array(await res.arrayBuffer())
    say('fetched', bytes.length, 'bytes')

    const book = await openFile(bytes)
    say('book built', book?.sections?.length, 'sections')

    // The custom element upgrades synchronously: view.js ran its
    // customElements.define before this module body executed.
    view = document.createElement('foliate-view')
    document.body.append(view)

    view.addEventListener('load', e => onSectionLoad(e.detail))
    view.addEventListener('relocate', e => {
        const { cfi, index, fraction } = e.detail
        post({
            type: 'relocated',
            index: index ?? 0,
            fraction: fraction ?? 0,
            total: view.book.sections.length,
            // A real foliate CFI — restore lands mid-chapter on reopen. (A
            // `doc@…` pseudo-CFI from the old pre-foliate pipeline is never
            // sent back here: the shell filters it out of the resume param.)
            cfi: cfi ?? '',
        })
    })
    view.addEventListener('external-link', e => {
        // The reader keeps its book: an external link posts and stands down
        // (the native reader script's policy for non-desktop schemes, minus
        // the top-level navigation that would blank the book).
        e.preventDefault()
        post({ type: 'external', href: String(e.detail?.href ?? '') })
        return false
    })

    say('opening the book')
    await view.open(book)
    say('book opened, laying out')
    // The Linux reader's RAM-bounded rendering: only the primary section
    // stays loaded (each section is its own iframe; neighbours are destroyed
    // once off-screen) — a 50 MB book never holds its whole render.
    view.renderer.setAttribute('no-continuous-scroll', '')
    applyRendererAttributes()
    applyShellGround()

    // The book's own nested contents — real chapters, real depths, straight
    // from the format's structure. The manifest carries the same rows (the
    // importer parsed with this very module), so this is a fallback for
    // books imported before the manifest had them.
    const toc = await flattenToc(book, book.toc ?? [], 0)
    const tocItems = toc.map(item => ({
        label: item.label,
        href: item.href,
        spineIndex: item.index,
        depth: item.depth,
    }))
    post({ type: 'toc', items: tocItems })

    // Resume: a real foliate CFI when there is one; else the manifest's
    // chapter + mid-chapter fraction (the old persistence — and the first
    // open's start chapter). The `doc@…` pseudo-CFI the pre-foliate
    // pipeline persisted is not a foliate CFI — it resumes by chapter +
    // fraction instead.
    say('initialising the view')
    const realCfi = resumeCfi && !resumeCfi.startsWith('doc@') ? resumeCfi : ''
    await view.init({ lastLocation: realCfi || undefined, showTextStart: !realCfi })
    if (!realCfi && (resumeChapter > 0 || resumeFraction > 0)) {
        const index = Math.max(0, Math.min(
            view.book.sections.length - 1, resumeChapter))
        await view.renderer.goTo({
            index,
            anchor: resumeFraction > 0 && resumeFraction <= 1
                ? resumeFraction : undefined,
        })
    }
    say('view ready')
    post({ type: 'ready' })
}

// The boot's milestones go to the console; a white pane gets diagnosed from
// the Safari inspector. A boot that never completes must still reach Swift:
// 45 s after the module loaded, if no 'ready'/'parseReady' was posted, say
// so through the channel — a white pane with a name beats a white pane alone.
let booted = false
window.addEventListener('load', () => {
    setTimeout(() => {
        if (!booted) post({
            type: 'error',
            message: 'the book engine did not finish loading (no ready within 45 s)',
        })
    }, 45000)
})

const boot = async () => {
    try {
        if (mode === 'parse') await bootParse()
        else await bootReader()
        booted = true
    } catch (e) {
        say('boot failed', e?.message ?? e)
        error(e?.message ?? e)
    }
}
boot()

// -- the Swift-callable command surface (reader mode) ------------------------
// The exact names BookWebView.evaluateJavaScript drives — same commands the
// epub.js shell answers, landing on the view (in-renderer, immediate).

window.readerGoChapter = index => {
    if (!view) return
    const target = parseInt(index, 10)
    if (!Number.isFinite(target)) return
    view.goTo(target).catch(() => {
        // An out-of-range index foliate could not resolve: the reader falls
        // back to the chapter it came from rather than keeping a bar that
        // lies.
        post({ type: 'goChapterFailed', index: target, reason: 'bad-target' })
    })
}
window.readerGoToHref = href => {
    if (!view || !href) return
    view.goTo(String(href)).catch(() => {})
}
window.readerNext = () => { view?.next() }
window.readerPrev = () => { view?.prev() }
window.readerAppearance = json => {
    if (!json) return
    const a = typeof json === 'string' ? JSON.parse(json) : json
    if (a.theme) appearance.theme = a.theme
    if (typeof a.fontSize === 'number') appearance.fontSize = a.fontSize
    if (a.font) appearance.font = a.font
    if (typeof a.lineHeight === 'number') appearance.lineHeight = a.lineHeight
    if (typeof a.paraSpacing === 'number') appearance.paraSpacing = a.paraSpacing
    if (typeof a.letterSpacing === 'number') appearance.letterSpacing = a.letterSpacing
    if (typeof a.margin === 'number') appearance.padding = a.margin
    if (typeof a.respectStyles === 'boolean') appearance.respectStyles = a.respectStyles
    if (typeof a.tapTurn === 'boolean') appearance.tapTurn = a.tapTurn
    if (typeof a.swipeTurn === 'boolean') appearance.swipeTurn = a.swipeTurn
    if (typeof a.tapInverted === 'boolean') appearance.tapInverted = a.tapInverted
    applyShellGround()
    applyRendererAttributes()
    for (const { doc } of (view?.renderer?.getContents?.() ?? [])) applyTypeLayer(doc)
}
window.readerFontSize = pct => {
    if (typeof pct !== 'number') return
    appearance.fontSize = pct
    for (const { doc } of (view?.renderer?.getContents?.() ?? [])) applyTypeLayer(doc)
}
window.readerTheme = mode2 => {
    if (!mode2) return
    appearance.theme = mode2
    applyShellGround()
    for (const { doc } of (view?.renderer?.getContents?.() ?? [])) applyTypeLayer(doc)
}
window.readerAutoScroll = (on, speed) => {
    if (typeof speed === 'number' && speed > 0) AUTO.speed = speed
    if (on) startAutoScroll()
    else stopAutoScroll()
}
window.readerAutoScrollSpeed = speed => {
    if (typeof speed === 'number' && speed > 0) AUTO.speed = speed
}
window.readerDestroy = () => {
    stopAutoScroll()
}
