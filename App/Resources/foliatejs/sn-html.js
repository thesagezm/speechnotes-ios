// The HTML loader — readest's makeHtmlBook (MIT) cut to this reader's
// needs. A saved page is parsed with DOMParser, the chrome-stripping
// Readability pass is NOT applied: the files this reader opens are books
// (Project Gutenberg mirrors, single-file saves of articles); Readability's
// 25-character rule eats front matter inside <pre> and byline blocks, and
// the whole body renders fine as the book itself. An HTMLZ (calibre's HTML
// zip) is unzipped first, its images kept as blob URLs; a standalone file's
// relative images were never servable (the old parser dropped those tags
// too) but data-URI inlined images (SingleFile saves) pass through.

import { buildDocBook } from './sn-docbook.js'

// UTF-8 strictly, then windows-1252 — the codepage web pages actually mean
// when the meta tag lies or is missing.
const decodeHtmlBytes = bytes => {
    try {
        return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
    } catch {
        return new TextDecoder('windows-1252').decode(bytes)
    }
}

// Split the body into sections at h1 boundaries (readest's rule): content
// before the first h1 is a preamble section; a document with no h1 stays
// one section. The TOC mirrors the full heading outline h1–h6 nested, each
// entry anchoring exactly where the heading sits — the book's contents page
// and the sidebar agree to the paragraph.
const sectionize = doc => {
    const groups = []
    let current = []
    const hasContent = nodes => nodes.some(n =>
        n.nodeType === Node.ELEMENT_NODE ||
        (n.nodeType === Node.TEXT_NODE && !!n.textContent?.trim()))
    for (const node of Array.from(doc.body.childNodes)) {
        if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'H1') {
            if (hasContent(current)) groups.push(current)
            current = [node]
        } else {
            current.push(node)
        }
    }
    if (hasContent(current)) groups.push(current)
    if (groups.length === 0) groups.push([])
    return groups
}

const chapterHtml = nodes => nodes
    .map(n => n.nodeType === Node.ELEMENT_NODE ? n.outerHTML : n.textContent)
    .join('')

export async function htmlToBook(bytes, { title, author }) {
    const html = decodeHtmlBytes(bytes)
    const doc = new DOMParser().parseFromString(html, 'text/html')

    const documentTitle = (doc.title ?? '').trim() || title
    const language = (doc.documentElement.getAttribute('lang') ?? '').trim()
    const dirAttr = (doc.documentElement.getAttribute('dir') ??
        doc.body?.getAttribute('dir') ?? '').trim().toLowerCase()
    const dir = dirAttr === 'rtl' ? 'rtl' : 'ltr'

    // Every heading gets a stable id, existing ids stay unique: the TOC
    // anchors and in-book links both resolve through getElementById.
    const usedIds = new Set(
        Array.from(doc.body?.querySelectorAll('[id]') ?? []).map(el => el.id))
    const uniqueId = base => {
        let id = base
        let n = 1
        while (usedIds.has(id)) id = `${base}-${n++}`
        usedIds.add(id)
        return id
    }
    const slugify = text =>
        text.toLowerCase().trim()
            .replace(/[^\w\s-]/g, '')
            .replace(/[\s_]+/g, '-')
            .replace(/^-+|-+$/g, '') || 'section'
    for (const h of Array.from(doc.body?.querySelectorAll('h1, h2, h3, h4, h5, h6') ?? [])) {
        if (!h.id) h.id = uniqueId(slugify(h.textContent ?? ''))
    }

    const groups = sectionize(doc)
    const chapters = groups.map(nodes => ({
        title: null,
        html: chapterHtml(nodes),
    }))

    // The heading outline as the nested TOC. Group indices here are section
    // indices directly, because every group is one section.
    const idMap = new Map()
    groups.forEach((nodes, index) => {
        for (const node of nodes) {
            if (node.nodeType !== Node.ELEMENT_NODE) continue
            if (node.id) idMap.set(node.id, index)
            for (const child of Array.from(node.querySelectorAll('[id]') ?? []))
                if (child.id) idMap.set(child.id, index)
        }
    })
    const root = []
    const stack = [{ level: 0, subitems: root }]
    for (const h of Array.from(doc.body?.querySelectorAll('h1, h2, h3, h4, h5, h6') ?? [])) {
        const label = (h.textContent ?? '').trim()
        if (!label) continue
        const level = Number(h.tagName.slice(1))
        const item = {
            label,
            index: idMap.get(h.id) ?? 0,
            anchorId: h.id,
            subitems: [],
        }
        while (stack.length > 1 && stack[stack.length - 1].level >= level) stack.pop()
        stack[stack.length - 1].subitems.push(item)
        stack.push({ level, subitems: item.subitems })
    }

    const book = buildDocBook(chapters, root, {
        title: documentTitle,
        author: author ?? '',
        language: language || undefined,
    }, dir)
    return book
}

// The HTMLZ: calibre's single-file HTML export — a zip holding the page and
// its images. The html file is extracted, every image becomes a blob URL,
// and the srcs are rewritten before the book is built, so the illustrations
// ship (the old parser kept these; this path keeps them too).
export async function htmlzToBook(bytes, zipMod, { title, author }) {
    const { configure, ZipReader, BlobReader, TextWriter, BlobWriter } = zipMod
    configure({ useWebWorkers: false })
    const file = new Blob([bytes])
    const reader = new ZipReader(new BlobReader(file))
    const entries = await reader.getEntries()
    const htmlEntry = entries.find(e => /\.x?html?$/i.test(e.filename))
        ?? entries[0]
    if (!htmlEntry) throw new Error('the archive holds no html file')
    const html = await htmlEntry.getData(new TextWriter())

    const images = new Map()
    for (const entry of entries) {
        if (!/\.(png|jpe?g|gif|webp|svg|bmp|avif)$/i.test(entry.filename)) continue
        const mime = entry.filename.toLowerCase().endsWith('.png') ? 'image/png'
            : entry.filename.toLowerCase().endsWith('.svg') ? 'image/svg+xml'
            : entry.filename.toLowerCase().endsWith('.gif') ? 'image/gif'
            : entry.filename.toLowerCase().endsWith('.webp') ? 'image/webp'
            : 'image/jpeg'
        const blob = await entry.getData(new BlobWriter(mime))
        images.set(entry.filename, URL.createObjectURL(blob))
    }

    // Rewrite each img src that names a zip entry to its blob URL. Paths in
    // the archive are matched by suffix, because the html's relative srcs
    // are relative to the html file's directory inside the zip.
    const rewritten = html.replace(/(<img\b[^>]*\bsrc=)(["'])([^"']+)\2/gi,
        (m, lead, quote, src) => {
            const clean = decodeURIComponent(src.split('?')[0].split('#')[0])
                .replace(/^\.\//, '')
            for (const [name, url] of images) {
                if (name === clean || name.endsWith('/' + clean)) {
                    return `${lead}${quote}${url}${quote}`
                }
            }
            return m
        })

    const book = await htmlToBook(new TextEncoder().encode(rewritten), { title, author })
    const destroySections = book.destroy
    book.destroy = () => {
        for (const url of images.values()) URL.revokeObjectURL(url)
        destroySections()
    }
    return book
}
