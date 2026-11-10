/*
 * html-to-markdown.js — article HTML → GitHub-Flavored Markdown.
 *
 * The second half of web-article import: Readability hands back the
 * article's DOM (`parsed.content`), this walker flattens it to the markdown
 * subset the app renders (MarkdownPreviewView / MarkdownText) and speaks
 * (MarkdownText.plainText strips every sigil emitted here):
 *
 *   headings h1-h6 → ##…   paragraphs   br → line break
 *   a → [text](href)       strong/em/del → **…* / *…* / ~~…~~
 *   code → `…`             pre → fenced block (language from class)
 *   ul/ol/li (nested) → list markers, task-checkbox → GFM task list
 *   blockquote → "> "      hr → ---     img → ![alt](src)
 *   table → GFM pipe table
 *
 * Everything else (script/style/iframes/forms/nav chrome, data: images,
 * javascript: links) is dropped. Link and image targets resolve against the
 * live page's base URI and are limited to http(s) — relative targets on a
 * page loaded with no base (local .html files) degrade to plain text rather
 * than dead file:// links.
 *
 * Emits GFM the cmark parser in MarkdownText accepts BY SPEC; markdown
 * significators in the article's own text are backslash-escaped so the
 * rendered note says what the page said. The whole walker is one pure
 * function over the DOM (`__snArticleToMarkdown`) — no page state is read
 * or written beyond it, and the caller wraps it in try/catch so any bug
 * here degrades an import to plain textContent, never to no-article.
 *
 * First-party file (not vendored): tested in Tests via a mock DOM, see
 * Docs/WEB-ARTICLE-IMPORT.md.
 */
(function (global) {
    'use strict';

    var ELEMENT_NODE = 1;
    var TEXT_NODE = 3;

    // Dropped outright, wherever they appear.
    var SKIP = {
        SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, IFRAME: 1, FRAME: 1,
        VIDEO: 1, AUDIO: 1, SVG: 1, CANVAS: 1, OBJECT: 1, EMBED: 1, MAP: 1,
        FORM: 1, BUTTON: 1, SELECT: 1, TEXTAREA: 1, OPTION: 1, LABEL: 1,
        FIELDSET: 1, LEGEND: 1, DIALOG: 1, LINK: 1, META: 1, HEAD: 1,
        TITLE: 1
    };

    var baseURI = '';

    function isElement(node) {
        return !!node && node.nodeType === ELEMENT_NODE;
    }

    function eachChild(node, fn) {
        var kids = node.childNodes || [];
        for (var i = 0; i < kids.length; i++) fn(kids[i]);
    }

    // Recursively collects descendant elements whose nodeName matches.
    function descendants(node, name, out) {
        eachChild(node, function (child) {
            if (!isElement(child)) return;
            if (child.nodeName === name) out.push(child);
            descendants(child, name, out);
        });
    }

    function spaces(n) {
        return new Array(n + 1).join(' ');
    }

    function collapse(text) {
        return String(text).replace(/\s+/g, ' ');
    }

    // Backslash-escape the sigils cmark treats as markup, so article text
    // like "2*3=6" or "a [b]" renders (and is spoken) literally.
    function esc(text) {
        return String(text).replace(/([\\`*_\[\]<>])/g, '\\$1');
    }

    // A paragraph (or heading, or list item) whose first line would start
    // with a block sigil gets it escaped — cmark would otherwise reparse
    // prose as a quote/list/heading.
    function escapeLineStart(text) {
        return text.replace(/^(\s*)([#>+-])/m, '$1\\$2');
    }

    // http(s) only, resolved against the live page. Anything else — data:,
    // javascript:, mailto:, file:, or a relative target with no base —
    // returns null and the caller degrades to plain text / nothing.
    function resolve(href) {
        if (!href) return null;
        var trimmed = collapse(href).replace(/\s/g, '');
        if (/^(data|javascript|mailto|tel|file|blob):/i.test(trimmed)) return null;
        if (!/^(https?:\/\/|\/|#)/i.test(trimmed)) return null;
        if (!baseURI) return null;
        try {
            var url = new URL(trimmed, baseURI);
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
            return url.href;
        } catch (err) {
            return null;
        }
    }

    function encodeDestination(href) {
        return href.replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');
    }

    // Best URL out of a srcset attribute: candidates are "url [descriptor]"
    // separated by commas. Scanned from the END — the last candidate is the
    // largest by convention — and the first one that resolves wins.
    function srcsetCandidate(attr) {
        if (!attr) return null;
        var parts = String(attr).split(',');
        for (var i = parts.length - 1; i >= 0; i--) {
            var url = collapse(parts[i]).trim().split(/\s+/)[0];
            if (!url) continue;
            var resolved = resolve(url);
            if (resolved) return resolved;
        }
        return null;
    }

    function imageMarkdown(img) {
        // Lazy-load pattern: `data-src` (and friends) holds the REAL image
        // while `src` is often a 1px placeholder or a tracking gif — the
        // real attributes go first, `srcset` last (it is the fallback
        // delivery for the same picture, not another image).
        var src = resolve(img.getAttribute('data-src'))
            || resolve(img.getAttribute('src'))
            || resolve(img.getAttribute('data-lazy-src'))
            || resolve(img.getAttribute('data-original'))
            || srcsetCandidate(img.getAttribute('data-srcset'))
            || srcsetCandidate(img.getAttribute('srcset'));
        if (!src) return '';
        var w = parseInt(img.getAttribute('width') || '', 10) || 0;
        var h = parseInt(img.getAttribute('height') || '', 10) || 0;
        if ((w > 0 && w <= 2) || (h > 0 && h <= 2)) return ''; // tracking pixel
        var alt = collapse(img.getAttribute('alt') || '');
        return '![' + esc(alt) + '](' + encodeDestination(src) + ')';
    }

    // The GFM task-list marker for an <input type=checkbox> (Notes renders
    // real checkboxes for these); any other input is noise — drop it.
    function inputMarkdown(input) {
        var type = (input.getAttribute('type') || '').toLowerCase();
        if (type !== 'checkbox') return '';
        return input.hasAttribute && input.hasAttribute('checked') ? '[x] ' : '[ ] ';
    }

    function wrap(delimiter, inner) {
        var text = collapse(inner).trim();
        return text ? delimiter + text + delimiter : text;
    }

    function inlineCode(node) {
        var text = node.textContent || '';
        if (!text.trim()) return '';
        var tick = text.indexOf('`') >= 0 ? '``' : '`';
        return tick + collapse(text).trim() + tick;
    }

    function linkMarkdown(a) {
        // An anchor wrapping exactly one image is a linked photo — notes
        // can't tap images, so the image itself IS the content. (Emitted as
        // [![…]](…) GFM would also depend on the renderer's span model
        // carrying link+image in one run.)
        var imgs = [];
        eachChild(a, function (child) {
            if (isElement(child) && child.nodeName === 'IMG') imgs.push(child);
            else if (isElement(child) && child.nodeName === 'PICTURE') {
                descendants(child, 'IMG', imgs);
            }
        });
        if (imgs.length === 1 && !(collapse(a.textContent || '').trim())) {
            return imageMarkdown(imgs[0]);
        }
        // inlineChildren — inline(a) would re-dispatch the anchor and
        // recurse forever.
        var label = collapse(inlineChildren(a)).trim();
        var href = resolve(a.getAttribute('href'));
        if (!href) return label;                       // dead target → plain text
        if (!label) return '<' + encodeDestination(href) + '>'; // naked anchor
        return '[' + label + '](' + encodeDestination(href) + ')';
    }

    // A <picture> resolves to ONE image: the <img> inside it when that
    // resolves (it carries the alt text), otherwise a <source>'s srcset.
    // Walking the children directly would emit both the source's and the
    // img's URL — two copies of the same photograph.
    function pictureMarkdown(picture) {
        var imgs = [];
        descendants(picture, 'IMG', imgs);
        if (imgs.length) {
            var md = imageMarkdown(imgs[0]);
            if (md) return md;
        }
        var sources = [];
        descendants(picture, 'SOURCE', sources);
        for (var i = 0; i < sources.length; i++) {
            var src = srcsetCandidate(sources[i].getAttribute('srcset'))
                || srcsetCandidate(sources[i].getAttribute('data-srcset'));
            if (src) {
                var alt = imgs.length ? collapse(imgs[0].getAttribute('alt') || '') : '';
                return '![' + esc(alt) + '](' + encodeDestination(src) + ')';
            }
        }
        return '';
    }

    // Inline context: runs of text with markup, newlines only for <br>.
    function inline(node) {
        if (node.nodeType === TEXT_NODE) return esc(collapse(node.nodeValue || ''));
        if (!isElement(node)) return '';
        var name = node.nodeName;
        if (name === 'INPUT') return inputMarkdown(node);
        if (SKIP[name]) return '';
        switch (name) {
            case 'BR':
                return '\n';
            case 'A':
                return linkMarkdown(node);
            case 'STRONG': case 'B':
                return wrap('**', inlineChildren(node));
            case 'EM': case 'I': case 'CITE': case 'VAR':
                return wrap('*', inlineChildren(node));
            case 'DEL': case 'S': case 'STRIKE':
                return wrap('~~', inlineChildren(node));
            case 'CODE': case 'TT': case 'KBD': case 'SAMP':
                return inlineCode(node);
            case 'IMG':
                return imageMarkdown(node);
            case 'PICTURE':
                // Wired-style `P > SPAN > PICTURE > IMG`: the image lives
                // INSIDE the picture element, so returning '' (the old
                // behavior) silently dropped every lazy `<picture>` photo.
                return pictureMarkdown(node);
            default:
                return inlineChildren(node);
        }
    }

    function inlineChildren(node) {
        var out = [];
        eachChild(node, function (child) { out.push(inline(child)); });
        return out.join('');
    }

    // One block's inline content: markup flattened, whitespace squeezed,
    // newlines (from <br>) preserved, edges trimmed. The space-run squeeze
    // joins the gaps browsers collapse around hidden/inline-block elements.
    function paragraphText(node) {
        return escapeLineStart(
            inlineChildren(node)
                .replace(/[ \t]*\n[ \t]*/g, '\n')
                .replace(/ {2,}/g, ' ')
                .trim()
        );
    }

    // Paragraphs that are page machinery, never content — matched against
    // the COLLAPSED WHOLE paragraph, case-insensitively, so a sentence that
    // merely mentions an ad survives. (NYT pages lead with a bare
    // "Advertisement" paragraph; caption toggles ride between figures.)
    var JUNK_PARAGRAPHS = {
        'advertisement': 1,
        'advertisementhide caption': 1,
        'advertisement hide caption': 1,
        'hide caption': 1,
        'toggle caption': 1,
        'skip advertisement': 1,
        'skip to main content': 1,
        'skip to content': 1,
    };

    // ---- Blocks -----------------------------------------------------------

    function headingMarkdown(node, level) {
        // The note's first line is the article headline (h1 territory), so
        // the walker shifts everything down one: h1 renders as ##. Levels
        // cap at ##### so deep outlines stay visually sane.
        var depth = Math.min(level + 1, 5);
        var marker = '';
        for (var i = 0; i < depth; i++) marker += '#';
        var text = collapse(inlineChildren(node)).trim();
        return text ? marker + ' ' + text : '';
    }

    function codeMarkdown(pre) {
        var code = (pre.textContent || '').replace(/^\n+/, '').replace(/\s+$/, '');
        if (!code.trim()) return '';
        // The language class rides the <code> child on most sites
        // (highlight.js/pygments), the <pre> itself on some.
        var classes = (pre.getAttribute('class') || '') + ' ' + (function () {
            var code = [];
            eachChild(pre, function (child) {
                if (isElement(child) && child.nodeName === 'CODE') code.push(child);
            });
            return code.length ? (code[0].getAttribute('class') || '') : '';
        })();
        var m = /(?:^|\s)(?:language|lang)-([\w#+-]+)/.exec(classes);
        var fence = code.indexOf('```') >= 0 ? '~~~~' : '```';
        return fence + (m ? m[1] : '') + '\n' + code + '\n' + fence;
    }

    function blockquoteMarkdown(node) {
        var inner = [];
        blocksOf(node, inner);
        var text = inner.filter(Boolean).join('\n\n');
        if (!text.trim()) return '';
        return text.split('\n').map(function (line) {
            return line.length ? '> ' + line : '>';
        }).join('\n');
    }

    // GFM pipe table. The first row becomes the header (GFM requires one);
    // ragged rows are padded so every line has the header's cell count.
    function tableMarkdown(node) {
        var trs = [];
        descendants(node, 'TR', trs);
        var rows = trs.map(function (tr) {
            var cells = [];
            // Children in document order — a cells-then-headers concat
            // would scramble rows that mix td and th.
            eachChild(tr, function (cell) {
                if (!isElement(cell)) return;
                if (cell.nodeName === 'TD' || cell.nodeName === 'TH') {
                    cells.push(collapse(inlineChildren(cell)).replace(/\|/g, '\\|').trim());
                }
            });
            return cells;
        }).filter(function (row) { return row.length > 0; });
        if (rows.length === 0) return '';
        var width = Math.max.apply(null, rows.map(function (r) { return r.length; }));
        var padded = rows.map(function (row) {
            var copy = row.slice();
            while (copy.length < width) copy.push('');
            return copy;
        });
        var header = padded[0];
        var rule = [];
        for (var i = 0; i < width; i++) rule.push('---');
        var lines = ['| ' + header.join(' | ') + ' |', '| ' + rule.join(' | ') + ' |'];
        for (var r = 1; r < padded.length; r++) lines.push('| ' + padded[r].join(' | ') + ' |');
        return lines.join('\n');
    }

    // A <dl>: terms become bold paragraphs, definitions plain ones (cmark
    // has no definition lists).
    function definitionListMarkdown(node) {
        var out = [];
        eachChild(node, function (child) {
            if (!isElement(child)) return;
            if (child.nodeName === 'DT') {
                var term = collapse(inlineChildren(child)).trim();
                if (term) out.push('**' + term + '**');
            } else if (child.nodeName === 'DD') {
                var def = paragraphText(child);
                if (def) out.push(def);
            }
        });
        return out.join('\n\n');
    }

    function listMarkdown(list, indent, ordered) {
        var lines = [];
        var index = 0;
        eachChild(list, function (child) {
            if (!isElement(child) || child.nodeName !== 'LI') return;
            index += 1;
            var marker = ordered ? index + '. ' : '- ';
            var text = '';
            var nested = [];
            eachChild(child, function (part) {
                if (isElement(part) && (part.nodeName === 'UL' || part.nodeName === 'OL')) {
                    var sub = listMarkdown(part, indent + marker.length, part.nodeName === 'OL');
                    sub.split('\n').forEach(function (line) { nested.push(line); });
                } else {
                    text += inline(part);
                }
            });
            text = collapse(text).trim();
            if (text || nested.length) {
                lines.push(spaces(indent) + marker + text);
                nested.forEach(function (line) { lines.push(line); });
            }
        });
        return lines.join('\n');
    }

    // The block walk: appends one string per structural block.
    function blocksOf(node, out) {
        eachChild(node, function (child) {
            if (child.nodeType === TEXT_NODE) {
                var text = collapse(child.nodeValue || '').trim();
                if (text) out.push(escapeLineStart(text));
                return;
            }
            if (!isElement(child)) return;
            var name = child.nodeName;
            if (SKIP[name]) return;
            switch (name) {
                case 'H1': out.push(headingMarkdown(child, 1)); return;
                case 'H2': out.push(headingMarkdown(child, 2)); return;
                case 'H3': out.push(headingMarkdown(child, 3)); return;
                case 'H4': out.push(headingMarkdown(child, 4)); return;
                case 'H5': out.push(headingMarkdown(child, 5)); return;
                case 'H6': out.push(headingMarkdown(child, 6)); return;
                case 'P': {
                    var text = paragraphText(child);
                    // Compare the UNESCAPED inner text — escapes and link
                    // syntax exist for the markdown parser, not for this
                    // lookup ("[SKIP ADVERTISEMENT](…) is still an ad").
                    var key = collapse(inlineChildren(child))
                        .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
                        .replace(/\\/g, '')
                        .trim().toLowerCase();
                    if (text && !JUNK_PARAGRAPHS[key]) {
                        out.push(text);
                    }
                    return;
                }
                case 'UL': out.push(listMarkdown(child, 0, false)); return;
                case 'OL': out.push(listMarkdown(child, 0, true)); return;
                case 'BLOCKQUOTE':
                    out.push(blockquoteMarkdown(child));
                    return;
                case 'PRE':
                    out.push(codeMarkdown(child));
                    return;
                case 'TABLE':
                    out.push(tableMarkdown(child));
                    return;
                case 'HR':
                    out.push('---');
                    return;
                case 'DL':
                    out.push(definitionListMarkdown(child));
                    return;
                case 'FIGCAPTION': {
                    var caption = collapse(inlineChildren(child)).trim();
                    if (caption) out.push('*' + caption + '*');
                    return;
                }
                case 'IMG': {
                    var img = imageMarkdown(child);
                    if (img) out.push(img);
                    return;
                }
                case 'PICTURE':
                    // Some sites emit <picture> as the block itself.
                    out.push(pictureMarkdown(child));
                    return;
                default:
                    // DIV/SECTION/ARTICLE/MAIN/FIGURE/BODY and anything
                    // unknown: keep walking — content inside wins.
                    blocksOf(child, out);
            }
        });
    }

    function normalize(text) {
        return collapse(text).trim().toLowerCase();
    }

    // Root entry. `title` is the article headline Readability extracted —
    // a leading heading equal to it is dropped so the note (whose first
    // line IS the title) doesn't print the headline twice.
    function toMarkdown(root, pageBaseURI, title) {
        baseURI = pageBaseURI || '';
        var out = [];
        blocksOf(root, out);
        var md = out.filter(function (block) {
            return block && block.trim().length > 0;
        }).join('\n\n');
        if (title) {
            // Anchor to the document's literal first line (headings are
            // single-line by construction) — a line-anchored regex would
            // eat a LATER heading that merely matches the title.
            var newlineAt = md.indexOf('\n');
            var firstLine = newlineAt >= 0 ? md.slice(0, newlineAt) : md;
            var m = /^#{1,6} (.+)$/.exec(firstLine);
            if (m && normalize(m[1]) === normalize(title)) {
                md = newlineAt >= 0 ? md.slice(newlineAt + 1).replace(/^\s+/, '') : '';
            }
        }
        return md.replace(/\n{3,}/g, '\n\n').trim();
    }

    global.__snArticleToMarkdown = toMarkdown;
})(typeof window !== 'undefined' ? window : this);
