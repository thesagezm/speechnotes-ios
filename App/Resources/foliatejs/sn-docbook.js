// The in-memory foliate-js book built from plain HTML strings — the shape
// readest's buildHtmlBook gives the Markdown/HTML loaders, trimmed to what
// this reader needs. The TXT chapteriser, the HTML loader and the RTF
// renderer all hand their output here: one section per chapter, a nested
// heading TOC, images served from the scheme's img/ space or as data URIs.
//
// Ported from readest's apps/readest-app/src/utils/htmlBook.ts (MIT), which
// is itself a port of the contract fb2.js gives single-file formats.

import * as CFI from './epubcfi.js'

const XHTML_NS = 'http://www.w3.org/1999/xhtml'

// The floor styles every generated section carries: images scale to the
// column, code and tables stay legible under any theme. currentColor keeps
// borders readable in dark mode.
const SECTION_STYLE = `
img { max-width: 100%; height: auto; }
pre { white-space: pre-wrap; overflow-wrap: break-word; }
pre, code { font-family: monospace; }
table { border-collapse: collapse; }
th, td { border: 1px solid currentColor; padding: 0.2em 0.5em; }
blockquote { margin-inline: 1em; }
`

const wrapXhtml = (inner, dir) =>
    '<?xml version="1.0" encoding="utf-8"?>\n' +
    `<html xmlns="${XHTML_NS}"${dir === 'rtl' ? ' dir="rtl"' : ''}><head>` +
    `<meta charset="utf-8"/><style>${SECTION_STYLE}</style></head>` +
    `<body>${inner}</body></html>`

const isExternalUri = uri => /^(?:https?|mailto|tel):/i.test(uri)

const slugify = text =>
    text.toLowerCase().trim()
        .replace(/[^\w\s-]/g, '')
        .replace(/[\s_]+/g, '-')
        .replace(/^-+|-+$/g, '') || 'section'

// `chapters`: [{ title: string|null, html: string }] — the body markup of
// each chapter, already escaped by its producer. `toc`: [{ label, index,
// anchorId, subitems }] — the nested contents; `anchorId` may be null.
// `metadata`: { title, author, language }. `dir`: 'ltr' | 'rtl'.
export function buildDocBook(chapters, toc, metadata, dir = 'ltr') {
    const serializer = new XMLSerializer()

    // Each chapter's markup goes through a real parse so the sections
    // serialise to well-formed XHTML: the producers emit HTML5 (void tags
    // like <br>, <img>), which are parse errors under application/xhtml+xml.
    // The parse also lifts every id — author-provided or generated — so the
    // TOC anchors and in-chapter links resolve; ids are made unique because
    // a repeated id would collapse its anchors onto the first occurrence.
    const idMap = new Map()
    const usedIds = new Set()
    const uniqueId = base => {
        let id = base
        let n = 1
        while (usedIds.has(id)) id = `${base}-${n++}`
        usedIds.add(id)
        return id
    }

    const parsedChapters = chapters.map(({ title, html }) => {
        const doc = new DOMParser().parseFromString(
            `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>${html}</body></html>`,
            'text/html')
        // The chapter's own title, when the producer carried one, becomes the
        // section's leading heading — the visible chapter title the reader
        // asked for — unless the body already opens with a heading (the
        // TXT chapteriser puts one there; the RTF renderer emits its own).
        if (title && doc.body.textContent.trim()) {
            const first = doc.body.firstElementChild
            const alreadyHeading = first && /^H[1-6]$/.test(first.tagName)
            const looksSame = alreadyHeading &&
                first.textContent.trim() === title.trim()
            if (!alreadyHeading || !looksSame) {
                const h = doc.createElement('h2')
                h.className = 'sn-chapter-title'
                h.textContent = title
                doc.body.prepend(h)
            }
        }
        for (const el of Array.from(doc.body.querySelectorAll('[id]'))) {
            if (el.id) {
                const unique = uniqueId(el.id)
                if (unique !== el.id) el.id = unique
                idMap.set(el.id, null) // filled with the section index below
            }
        }
        return { doc }
    })

    const xhtml = parsedChapters.map(({ doc }, index) => {
        for (const el of Array.from(doc.body.querySelectorAll('[id]'))) {
            if (el.id) idMap.set(el.id, index)
        }
        const inner = Array.from(doc.body.childNodes)
            .map(node => serializer.serializeToString(node))
            .join('')
        return wrapXhtml(inner, dir)
    })

    // The nested TOC as foliate wants it: label + href (`<index>#<id>`).
    const buildToc = items => items
        .filter(item => item.label && item.label.trim())
        .map(item => ({
            label: item.label.trim(),
            href: `${item.index}#${item.anchorId ?? ''}`.replace(/#$/, ''),
            subitems: item.subitems?.length ? buildToc(item.subitems) : undefined,
        }))
    const foliateToc = buildToc(toc)

    const urls = new Array(xhtml.length).fill(undefined)
    const sections = xhtml.map((str, index) => ({
        id: String(index),
        // foliate builds location CFIs as `section.cfi ?? CFI.fake.fromIndex
        // (index)`; an empty string would defeat that fallback and collapse
        // every saved position to a section-less CFI. Readest's comment
        // taught this: set the fake spine CFI foliate would synthesise.
        cfi: CFI.fake.fromIndex(index),
        size: new TextEncoder().encode(str).length,
        linear: 'yes',
        load: () => {
            if (urls[index] === undefined)
                urls[index] = URL.createObjectURL(
                    new Blob([str], { type: 'application/xhtml+xml' }))
            return urls[index]
        },
        createDocument: async () =>
            new DOMParser().parseFromString(str, 'application/xhtml+xml'),
    }))

    const resolveHref = href => {
        const [a, b] = href.split('#')
        if (a) {
            const index = Number(a)
            if (!Number.isInteger(index) || index < 0 || index >= sections.length)
                return null
            return { index, anchor: doc => b ? doc.getElementById(b) : null }
        }
        if (!b) return null
        const index = idMap.get(b)
        if (index === undefined) return null
        return { index, anchor: doc => doc.getElementById(b) }
    }

    return {
        metadata,
        rendition: { layout: 'reflowable' },
        dir,
        toc: foliateToc,
        sections,
        // The split/read pair TOCProgress needs to report the current TOC
        // item as the reader moves (the relocate's tocItem.label).
        splitTOCHref: href => href ? href.split('#') : [],
        getTOCFragment: (doc, id) => doc.getElementById(id),
        resolveHref,
        resolveCFI: null,
        isExternal: uri => isExternalUri(uri),
        getCover: async () => null,
        destroy: () => {
            for (const url of urls) if (url) URL.revokeObjectURL(url)
        },
    }
}

// A synthetic book built by a producer that failed to find any chapter
// structure: one section per chunk is the caller's problem; this is the
// "the book opened but has no contents" floor.
export const singleSectionBook = (html, metadata) =>
    buildDocBook([{ title: null, html }], [], metadata)
