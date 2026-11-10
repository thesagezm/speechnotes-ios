'use strict';
// Dev harness for App/Resources/JS/html-to-markdown.js — runs the walker
// against a minimal DOM mock (the exact API surface it touches: nodeType,
// nodeName, childNodes, nodeValue, getAttribute, hasAttribute, textContent)
// and asserts the emitted GFM. Not part of the iOS build.
const vm = require('vm');
const fs = require('fs');

const SRC = require("path").join(__dirname, "..", "App", "Resources", "JS", "html-to-markdown.js");
const sandbox = { URL, console };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(SRC, 'utf8'), sandbox);
const toMd = sandbox.__snArticleToMarkdown;
if (typeof toMd !== 'function') { console.error('walker did not install'); process.exit(1); }

// ---- mock DOM ----
function text(s) { return { nodeType: 3, nodeValue: s, childNodes: [] }; }
function el(name, attrs = {}, ...children) {
  return {
    nodeType: 1,
    nodeName: name.toUpperCase(),
    attrs,
    childNodes: children,
    getAttribute(n) { const v = this.attrs[n]; return v === undefined ? null : v; },
    hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n); },
    get textContent() {
      return this.childNodes.map(c => (c.nodeType === 3 ? c.nodeValue : c.textContent)).join('');
    },
  };
}

let pass = 0, fail = 0;
function check(label, actual, expected) {
  if (actual === expected) { pass++; console.log(`  ok  ${label}`); }
  else {
    fail++;
    console.log(`FAIL  ${label}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  }
}
const md = (dom, base, title) => toMd(dom, base, title || '');

// ---- 1. headings shift down one level ----
check('h1 -> ##',
  md(el('div', {}, el('div', {}, el('h1', {}, text('Chapter One'))))),
  '## Chapter One');
check('h2 -> ### / h3 -> ####',
  md(el('div', {}, el('div', {}, el('h2', {}, text('A')), text(' mid '), el('h3', {}, text('B'))))),
  '### A\n\nmid\n\n#### B');
check('h6 caps at #####',
  md(el('div', {}, el('div', {}, el('h6', {}, text('deep'))))),
  '##### deep');

// ---- 2. title dedupe on the literal first line ----
check('leading h1 equal to title is dropped',
  md(el('div', {}, el('div', {}, el('h1', {}, text('The Title')), el('p', {}, text('Body here')))), 'https://x.com/', 'The Title'),
  'Body here');
check('title match is case/whitespace-insensitive',
  md(el('div', {}, el('div', {}, el('h1', {}, text('  the  TITLE ')), el('p', {}, text('Body')))), 'https://x.com/', 'The Title'),
  'Body');
check('non-matching first heading survives',
  md(el('div', {}, el('div', {}, el('h1', {}, text('Other')), el('p', {}, text('Body')))), 'https://x.com/', 'The Title'),
  '## Other\n\nBody');
check('matching heading LATER in the doc is NOT dropped',
  md(el('div', {}, el('div', {}, el('p', {}, text('Intro')), el('h1', {}, text('The Title')))), 'https://x.com/', 'The Title'),
  'Intro\n\n## The Title');

// ---- 3. inline markup ----
check('strong/em/del',
  md(el('div', {}, el('p', {}, el('strong', {}, text('bold')), text(' and '), el('em', {}, text('ital')), text(' and '), el('del', {}, text('gone'))))),
  '**bold** and *ital* and ~~gone~~');
check('br -> line break inside a paragraph',
  md(el('div', {}, el('p', {}, text('line one'), el('br', {}), text('line two')))),
  'line one\nline two');
check('inline code',
  md(el('div', {}, el('p', {}, el('code', {}, text('x = f(y)'))))),
  '`x = f(y)`');
check('markdown sigils in prose are escaped',
  md(el('div', {}, el('p', {}, text('2*3=6, _under_, a [b] and <tag>')))),
  '2\\*3=6, \\_under\\_, a \\[b\\] and \\<tag\\>');
check('paragraph starting with a block sigil is escaped',
  md(el('div', {}, el('p', {}, text('- not a list')))),
  '\\- not a list');

// ---- 4. links ----
check('relative href resolves against page base',
  md(el('div', {}, el('p', {}, el('a', { href: '/other/story' }, text('Related')))), 'https://example.com/post/x'),
  '[Related](https://example.com/other/story)');
check('absolute http link kept as-is',
  md(el('div', {}, el('p', {}, el('a', { href: 'https://elsewhere.org/a(b)' }, text('out')))), 'https://example.com/'),
  '[out](https://elsewhere.org/a%28b%29)');
check('javascript: href degrades to plain text',
  md(el('div', {}, el('p', {}, el('a', { href: 'javascript:void(0)' }, text('click')))), 'https://example.com/'),
  'click');
check('mailto: href degrades to plain text',
  md(el('div', {}, el('p', {}, el('a', { href: 'mailto:a@b.c' }, text('mail')))), 'https://example.com/'),
  'mail');
check('no base (local file) -> relative link degrades to text',
  md(el('div', {}, el('p', {}, el('a', { href: '/x' }, text('rel')))), ''),
  'rel');
check('fragment link resolves against page',
  md(el('div', {}, el('p', {}, el('a', { href: '#footnote-1' }, text('1')))), 'https://example.com/p'),
  '[1](https://example.com/p#footnote-1)');
check('linked image -> the image itself (notes cannot tap images)',
  md(el('div', {}, el('p', {}, el('a', { href: 'https://example.com/big.jpg' }, el('img', { src: 'https://example.com/big.jpg', alt: 'pic' })))), 'https://example.com/'),
  '![pic](https://example.com/big.jpg)');
check('linked image with different href keeps the image',
  md(el('div', {}, el('p', {}, el('a', { href: 'https://example.com/post' }, el('img', { src: 'https://example.com/thumb.jpg', alt: 'teaser' })))), 'https://example.com/'),
  '![teaser](https://example.com/thumb.jpg)');

// ---- 5. lists ----
check('simple ul',
  md(el('div', {}, el('ul', {},
    el('li', {}, text('first')),
    el('li', {}, text('second'))))),
  '- first\n- second');
check('nested ul indents under the marker',
  md(el('div', {}, el('ul', {},
    el('li', {}, text('outer'),
      el('ul', {}, el('li', {}, text('inner-a')), el('li', {}, text('inner-b')))),
    el('li', {}, text('next'))))),
  '- outer\n  - inner-a\n  - inner-b\n- next');
check('ol numbering',
  md(el('div', {}, el('ol', {},
    el('li', {}, text('one')),
    el('li', {}, text('two'))))),
  '1. one\n2. two');
check('ol with nested ul',
  md(el('div', {}, el('ol', {}, el('li', {}, text('step'),
    el('ul', {}, el('li', {}, text('detail'))))))),
  '1. step\n   - detail');
check('task list checkboxes',
  md(el('div', {}, el('ul', {},
    el('li', {}, el('input', { type: 'checkbox', checked: '' }), text('done thing')),
    el('li', {}, el('input', { type: 'checkbox' }), text('open thing'))))),
  '- [x] done thing\n- [ ] open thing');
check('non-li junk in a list is skipped',
  md(el('div', {}, el('ul', {}, text('  '), el('li', {}, text('item')), el('script', {}, text('bad()'))))),
  '- item');

// ---- 6. blockquote / code / hr / dl ----
check('blockquote prefixes every line',
  md(el('div', {}, el('blockquote', {}, el('p', {}, text('wise words')), el('p', {}, text('more wisdom'))))),
  '> wise words\n>\n> more wisdom');
check('nested blockquote',
  md(el('div', {}, el('blockquote', {}, el('p', {}, text('outer')), el('blockquote', {}, el('p', {}, text('inner')))))),
  '> outer\n>\n> > inner');
check('pre>code fenced with language',
  md(el('div', {}, el('pre', {}, el('code', { class: 'language-swift' }, text('let x = 1\nlet y = 2'))))),
  '```swift\nlet x = 1\nlet y = 2\n```');
check('code containing triple backticks uses ~~~~ fence',
  md(el('div', {}, el('pre', {}, el('code', {}, text('a\n```\nb'))))),
  '~~~~\na\n```\nb\n~~~~');
check('hr -> ---',
  md(el('div', {}, el('div', {}, el('p', {}, text('before')), el('hr', {}), el('p', {}, text('after'))))),
  'before\n\n---\n\nafter');
check('dl -> bold terms + paragraphs',
  md(el('div', {}, el('dl', {}, el('dt', {}, text('Term')), el('dd', {}, text('Definition here'))))),
  '**Term**\n\nDefinition here');

// ---- 7. tables ----
check('gfm table, ragged rows padded',
  md(el('div', {}, el('table', {},
    el('tr', {}, el('th', {}, text('Name')), el('th', {}, text('Qty'))),
    el('tr', {}, el('td', {}, text('Apples')), el('td', {}, text('4'))),
    el('tr', {}, el('td', {}, text('Pears')))))),
  '| Name | Qty |\n| --- | --- |\n| Apples | 4 |\n| Pears |  |');
check('pipes inside cells are escaped',
  md(el('div', {}, el('table', {}, el('tr', {}, el('td', {}, text('a|b')))))),
  '| a\\|b |\n| --- |');
check('thead/tbody structure is flattened',
  md(el('div', {}, el('table', {},
    el('thead', {}, el('tr', {}, el('th', {}, text('H')))),
    el('tbody', {}, el('tr', {}, el('td', {}, text('V'))))))),
  '| H |\n| --- |\n| V |');

// ---- 8. images ----
check('relative img resolves',
  md(el('div', {}, el('p', {}, el('img', { src: '/img/hero.jpg', alt: 'Hero shot' }))), 'https://example.com/post'),
  '![Hero shot](https://example.com/img/hero.jpg)');
check('data: img dropped',
  md(el('div', {}, el('p', {}, el('img', { src: 'data:image/png;base64,AAAA', alt: 'x' }))), 'https://example.com/'),
  '');
check('tracking pixel (width 1) dropped',
  md(el('div', {}, el('p', {}, el('img', { src: 'https://example.com/t.gif', width: '1', height: '1' }))), 'https://example.com/'),
  '');
check('lazy data-src picked up',
  md(el('div', {}, el('p', {}, el('img', { 'data-src': 'https://cdn.example.com/a.png', alt: '' }))), 'https://example.com/'),
  '![](https://cdn.example.com/a.png)');
check('data-src beats placeholder src (lazy pattern)',
  md(el('div', {}, el('p', {}, el('img', { src: 'https://example.com/1px.gif', 'data-src': 'https://cdn.example.com/real.jpg', alt: 'real' }))), 'https://example.com/'),
  '![real](https://cdn.example.com/real.jpg)');
check('picture > img resolves (lazy <picture> markup)',
  md(el('div', {}, el('p', {}, el('span', {}, el('picture', {},
    el('source', { srcset: 'https://cdn.example.com/w320.jpg 320w', media: '(max-width: 320px)' }),
    el('img', { src: 'https://cdn.example.com/hero.jpg', alt: 'Hero' }))))), 'https://example.com/'),
  '![Hero](https://cdn.example.com/hero.jpg)');
check('picture with source-only srcset falls back to the source',
  md(el('div', {}, el('picture', {},
    el('source', { srcset: 'https://cdn.example.com/s1.jpg 1x, https://cdn.example.com/s2.jpg 2x' }),
    el('img', { alt: 'From source' }))), 'https://example.com/'),
  '![From source](https://cdn.example.com/s2.jpg)');
check('srcset fallback picks the last (largest) candidate',
  md(el('div', {}, el('p', {}, el('img', { srcset: 'https://cdn.example.com/a.jpg 400w, https://cdn.example.com/b.jpg 1200w', alt: 'big' }))), 'https://example.com/'),
  '![big](https://cdn.example.com/b.jpg)');
check('bare advertisement paragraph dropped',
  md(el('div', {}, el('p', {}, text('Advertisement')), el('p', {}, text('Real body')))),
  'Real body');
check('caption toggle paragraph dropped',
  md(el('div', {}, el('p', {}, text('Hide caption')), el('p', {}, text('body')))),
  'body');
check('a paragraph that merely MENTIONS an ad survives',
  md(el('div', {}, el('p', {}, text('The advertisement industry is changing')))),
  'The advertisement industry is changing');

// ---- 9. dropped structure ----
check('script/style/iframe/form noise dropped',
  md(el('div', {}, el('div', {},
    el('script', {}, text('evil()')),
    el('style', {}, text('.x{}')),
    el('iframe', { src: 'https://ads.example.com' }),
    el('form', {}, el('input', { type: 'text' })),
    el('p', {}, text('real content'))))),
  'real content');
check('empty containers produce nothing',
  md(el('div', {}, el('div', {}, el('div', {}), text('   '), el('section', {}, text(''))))),
  '');
check('figure keeps img + italic caption',
  md(el('div', {}, el('figure', {},
    el('img', { src: 'https://example.com/pic.jpg', alt: 'The pic' }),
    el('figcaption', {}, text('Caption text')))), 'https://example.com/'),
  '![The pic](https://example.com/pic.jpg)\n\n*Caption text*');

// ---- 10. whitespace discipline ----
check('runs of blank lines collapse',
  md(el('div', {}, el('div', {},
    el('div', {}, el('p', {}, text('a')), el('p', {}, text('')), el('p', {}, text(''))),
    el('p', {}, text('b'))))),
  'a\n\nb');
check('text whitespace collapses (multi-line source HTML)',
  md(el('div', {}, el('p', {}, text('one\n   two\tthree   four')))),
  'one two three four');

// ---- 11. structural wrappers recurse ----
check('article/section/div wrappers flatten',
  md(el('div', {}, el('article', {},
    el('section', {},
      el('div', {}, el('h2', {}, text('Sec')), el('p', {}, text('text'))))))),
  '### Sec\n\ntext');
check('svg and video dropped inside paragraphs',
  md(el('div', {}, el('p', {}, text('before '), el('svg', {}, text('<path/>')), el('video', { src: 'x.mp4' }), text(' after')))),
  'before after');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
