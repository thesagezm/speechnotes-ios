// The plain-text chapteriser: readest's TxtToEpubConverter logic, ported
// from apps/readest-app/src/utils/txt.ts (MIT) and cut back to what this
// reader needs (no in-memory EPUB zip — the chapters feed sn-docbook.js
// directly; no large-file streaming — the import path caps documents at
// 512 MB and this view holds the file's bytes anyway).
//
// The design points worth keeping, because they are the difference between
// a book's contents and a table of junk:
//   * headings are matched against a small whitelist of patterns, anchored
//     to line starts;
//   * a candidate split is *rejected outright* when it produces one
//     oversized segment (`isGoodMatches`) — the title-matches-everywhere
//     failure that lists a book's front matter as chapters (readest #4063,
//     #6172);
//   * content that follows a real chapter but carries no heading of its own
//     (scene breaks split on dash dividers) merges into that chapter instead
//     of becoming a bogus TOC row;
//   * when no pattern matches at all, the text falls back to fixed-size
//     paragraph chunks — numbered, unlabelled, honest about being guesses.

const escapeXml = str => str
    .replace(/[&<>"']/g, ch => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[ch]))

// CJK numeral vocabulary, from readest: beyond 一二三…, 两/兩 (colloquial
// "two"), 壹贰叁… (formal numerals of classical editions) and the arabic
// digits; a numeral style left out glues its chapters into one oversized
// part that isGoodMatches then rejects, dropping the TOC for the whole book.
const CJK_NUMBER_DIGITS = '零〇一二两兩三四五六七八九十壹贰貳叁叄參肆伍陆陸柒捌玖拾0-9'
const CJK_NUMBER_UNITS = '百千万萬佰仟'
const CJK_NUMBER_CHARS = `${CJK_NUMBER_DIGITS}${CJK_NUMBER_UNITS}`
const CJK_VOLUME_HEADING = new RegExp(
    `第[ 　]*[${CJK_NUMBER_CHARS}][ 　${CJK_NUMBER_CHARS}]*(卷|本|册|冊|部)`)

const CHAPTER_KEYWORDS = ['Chapter', 'Part', 'Section', 'Book', 'Volume', 'Act']
const PREFACE_KEYWORDS = [
    'Prologue', 'Epilogue', 'Introduction', 'Foreword', 'Preface', 'Afterword',
]

const detectLanguage = text => {
    const sample = (text ?? '').slice(0, 4096)
    if (!sample) return 'en'
    const total = sample.replace(/\s/g, '').length || 1
    const count = re => (sample.match(re) ?? []).length
    const cjk = count(/[\u4e00-\u9fff\u3400-\u4dbf]/g) / total
    const kana = count(/[\u3040-\u30ff]/g) / total
    const hangul = count(/[\uac00-\ud7af\u1100-\u11ff]/g) / total
    const cyrillic = count(/[\u0400-\u04ff]/g) / total
    if (kana > 0.02) return 'ja'
    if (cjk > 0.1) return 'zh'
    if (hangul > 0.05) return 'ko'
    if (cyrillic > 0.2) return 'ru'
    return 'en'
}

// A line standing alone that plausibly names a chapter is matched by the
// regexps below; `isGoodMatches` guards the split as a whole.
const createChapterRegexps = language => {
    const chapterRegexps = []

    if (language === 'zh') {
        const cjkNumber = `第[ 　${CJK_NUMBER_DIGITS}][ 　${CJK_NUMBER_CHARS}]*`
        // Tier 1 — chapter units; the title may attach directly or after a
        // separator. Tier 2 — volume units double as measure words in prose
        // (第一封信), so a title only counts when introduced by a separator
        // or the line ends (readest #4658).
        const chapterUnit = String.raw`[章节節回讲講篇话話](?:[：:、 　\(\)0-9]*[^\n-]{0,36})`
        const volumeUnit = String.raw`[卷本册冊部封](?:[：:、 　\(\)][：:、 　\(\)0-9]*[^\n-]{0,36})?`
        const numberedHeading = String.raw`${cjkNumber}(?:${chapterUnit}|${volumeUnit})(?!\S)`
        const prefaceHeading = String.raw`(?:楔子|前言|简介|引言|序言|序章|总论|概论|后记|番外篇|番外|外传)(?:[：: 　][^\n-]{0,36})?(?!\S)`
        const englishHeading = String.raw`chapter[\s.]*[0-9]+(?:[：:. 　]+[^\n-]{0,50})?(?!\S)`
        chapterRegexps.push(new RegExp(
            String.raw`(?:^|\n)\s*(` +
            [numberedHeading, prefaceHeading, englishHeading].join('|') + ')',
            'gui'))
        chapterRegexps.push(new RegExp(
            String.raw`(?:^|\n)\s*(` +
            [
                String.raw`[一二三四五六七八九十][零〇一二三四五六七八九十百千万]?[：:、 　][^\n-]{0,36}(?=\n|$)`,
                String.raw`[0-9]+[^\n]{0,16}(?=\n|$)`,
            ].join('|') + ')',
            'gu'))
        return chapterRegexps
    }

    const numberPattern = String.raw`(?:\d+|(?:[IVXLCDM]{2,}|V|X|L|C|D|M)\b)`
    const dotNumberPattern = String.raw`\.\d{1,4}`
    const titlePattern = String.raw`[^\n]{0,50}`

    const normalChapterPattern = CHAPTER_KEYWORDS
        .map(k =>
            String.raw`${k}\s*(?:${numberPattern}|${dotNumberPattern})(?:[:.\-–—]?\s*${titlePattern})?`)
        .join('|')
    const prefacePattern = PREFACE_KEYWORDS
        .map(k => String.raw`${k}(?:[:.\-–—]?\s*${titlePattern})?`)
        .join('|')

    chapterRegexps.push(new RegExp(
        String.raw`(?:^|\n)(${normalChapterPattern}|${prefacePattern})(?=\s|$)`,
        'gi'))

    // Second tier: bare numbered headings like "1.1 The Elements" — dotted
    // numbers allow a space before the title, single digits do not (so a
    // footnote's "1 The Lisp…" never matches).
    chapterRegexps.push(new RegExp(
        String.raw`(?:^|\n)(\d+\.\d+(?:\.\d+)* ?[A-Z][^\n]{0,80}|\d+[A-Z][^\n]{0,80})`,
        'g'))

    return chapterRegexps
}

// The split is trustworthy only when it actually split something and no
// segment is a whole book by itself: a pattern that fires on every
// occurrence of a word produces one massive "segment" and a wall of bogus
// one-line chapters at once.
const isGoodMatches = (matches, maxLength = 100000) => {
    const meaningful = matches.filter(part => part && part.trim().length > 0)
    if (meaningful.length <= 1) return false
    return !meaningful.some(part => part.length > maxLength)
}

// readest's joinAroundUndefined: a split with an empty capture at a boundary
// would otherwise begin a chapter's text with undefined-glued fragments.
const joinAroundUndefined = arr => arr.reduce((acc, curr, i, src) => {
    if (curr === undefined && i > 0 && i < src.length - 1 &&
        src[i - 1] !== undefined && src[i + 1] !== undefined) {
        acc[acc.length - 1] += src[i + 1]
        return acc
    }
    if (curr !== undefined && (i === 0 || src[i - 1] !== undefined)) {
        acc.push(curr)
    }
    return acc
}, [])

const formatSegment = segment => escapeXml(segment)
    .replace(/-{8,}|_{8,}/g, '\n')
    .split(/\n+/)
    .map(line => line.trim())
    .filter(line => line)
    .join('</p><p>')

// A paragraph-chunk fallback chapter: honest about being a guess.
const chunkChapter = (text, title) => ({
    title,
    isVolume: false,
    detected: false,
    html: `<h2>${escapeXml(title)}</h2><p>${formatSegment(text)}</p>`,
})

// Decode a byte array: UTF-16 by its BOM when the file carries one (the
// ladder's 8-bit decoders would otherwise interleave NULs through the text
// — mojibake that also breaks the sections' XHTML: NUL is not a valid XML
// character), then UTF-8 strictly when it is UTF-8, then the WebKit
// decoders for the codepages the corpus actually ships (GBK, Shift-JIS,
// windows-1251/1252, ISO-8859-x), latin-1 as the floor that never fails.
const decodeTxt = bytes => {
    if (bytes.length >= 2) {
        if (bytes[0] === 0xff && bytes[1] === 0xfe)
            return new TextDecoder('utf-16le').decode(bytes)
        if (bytes[0] === 0xfe && bytes[1] === 0xff)
            return new TextDecoder('utf-16be').decode(bytes)
    }
    for (const encoding of ['utf-8', 'gb18030', 'big5', 'shift_jis',
        'windows-1251', 'windows-1252', 'iso-8859-7']) {
        try {
            const text = new TextDecoder(encoding, { fatal: true }).decode(bytes)
            // utf-8 is fatal-decoded; the others decode nearly anything, so
            // a decodable-but-wrong codepage shows as mojibake — accept the
            // first decode that produces no replacement characters.
            if (encoding === 'utf-8' || !text.includes('\ufffd')) return text
        } catch { /* try the next codepage */ }
    }
    return new TextDecoder('latin1').decode(bytes)
}

// The one entry: bytes → { chapters, title, author, language } for
// sn-docbook. `title` falls back to the file's stem (the caller supplies it
// from the manifest when the text carries none).
export function txtToChapters(bytes) {
    const text = decodeTxt(bytes).trim()
    if (!text) throw new Error('the file has no readable text')

    const language = detectLanguage(text.slice(0, 2048))
    const chapterRegexps = createChapterRegexps(language)
    const fallbackParagraphsPerChapter = 100

    // Split segments on runs of blank lines or dash rules, chapterise each.
    // The segment regex also fires on dash dividers, which authors use as
    // in-chapter scene breaks: the content after such a divider has no
    // heading of its own, so when it follows a detected chapter it merges
    // into that chapter instead of becoming a bogus TOC row (#4063).
    const appendSegmentChapters = (list, segmentChapters) => {
        for (const chapter of segmentChapters) {
            const previous = list[list.length - 1]
            if (!chapter.detected && previous?.detected) {
                previous.html += chapter.html
                    .replace(/^<h[1-6][^>]*>[\s\S]*?<\/h[1-6]>/, '')
            } else {
                list.push(chapter)
            }
        }
    }

    const segmentRegex = /(?:\r?\n){8,}|-{8,}\r?\n/
    const chapters = []
    for (const segment of text.split(segmentRegex)) {
        const trimmed = segment.trim()
        if (!trimmed) continue

        let matches = []
        for (const chapterRegex of chapterRegexps) {
            const tryMatches = trimmed.split(chapterRegex)
            if (isGoodMatches(tryMatches)) {
                matches = joinAroundUndefined(tryMatches)
                break
            }
        }

        if (matches.length === 0) {
            // No trusted pattern: fixed paragraph chunks, if anything.
            const paragraphs = trimmed.split(/\n+/)
            const segmentChapters = []
            for (let i = 0; i < paragraphs.length; i += fallbackParagraphsPerChapter) {
                const chunks = paragraphs.slice(i, i + fallbackParagraphsPerChapter)
                const title = `${chapters.length + segmentChapters.length + 1}`
                segmentChapters.push(chunkChapter(chunks.join('\n'), title))
            }
            appendSegmentChapters(chapters, segmentChapters)
            continue
        }

        const segmentChapters = []
        for (let j = 1; j < matches.length; j += 2) {
            const title = (matches[j] ?? '').trim()
            const content = (matches[j + 1] ?? '').trim()
            const isVolume = language === 'zh'
                ? CJK_VOLUME_HEADING.test(title)
                : /\b(Part|Volume|Book)\b/i.test(title)
            const headTitle = isVolume
                ? `<h1>${escapeXml(title)}</h1>`
                : `<h2>${escapeXml(title)}</h2>`
            segmentChapters.push({
                title: escapeXml(title),
                isVolume,
                detected: true,
                html: `${headTitle}<p>${formatSegment(content)}</p>`,
            })
        }
        // Content before the first heading in this segment: its own
        // heading-less chunk, which the append rule merges forward when the
        // previous chapter was detected.
        if (matches[0] && matches[0].trim()) {
            const initial = matches[0].trim()
            const firstLine = initial.split('\n')[0].trim()
            const title = (firstLine.length > 16
                ? initial.split(/[\n\s\p{P}]/u)[0].trim()
                : firstLine) || initial.slice(0, 16)
            segmentChapters.unshift({
                title: escapeXml(title),
                isVolume: false,
                detected: false,
                html: `<h2>${escapeXml(title)}</h2><p>${formatSegment(initial)}</p>`,
            })
        }
        appendSegmentChapters(chapters, segmentChapters)
    }

    if (chapters.length === 0)
        chapters.push(chunkChapter(text, ''))
    return { chapters, language }
}
