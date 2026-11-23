'use strict';
// Dev harness for the reader-mode extraction script that rides inside
// WebArticleService.readabilityExtract.
//
// The script is a Swift string literal (one source of truth — it must
// not be copied into a file here), so this harness EXTRACTS it from
// App/Sources/Services/WebArticleService.swift, swaps the injected plan
// for the real one (SpeechLogic's ReaderModeExtraction lists, mirrored
// here — the Swift side injects the same JSON), and runs it against a
// minimal DOM mock.
//
// What it pins:
//   * the CHROME PRE-STRIP removes nav/footer/form furniture before the
//     article is chosen;
//   * the ARTICLE FAST PATH takes a page's <article> as the article,
//     without the scoring;
//   * the fast path hands back MARKDOWN (textContent would run the
//     paragraphs together), with the leading headline dropped;
//   * a page with no article root falls through to the scored path.
//
// Not part of the iOS build. Run: node Scripts/test-reader-mode-extraction.js
const vm = require('vm');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..');
const SERVICE = path.join(REPO, 'App', 'Sources', 'Services', 'WebArticleService.swift');
const WALKER = path.join(REPO, 'App', 'Resources', 'JS', 'html-to-markdown.js');

// ---- the script, extracted from the Swift string literal ----------------
function extractScript() {
  const src = fs.readFileSync(SERVICE, 'utf8');
  const match = src.match(/let js = """\n([\s\S]*?)\n\s*"""/);
  if (!match) { console.error('could not find the extraction script in WebArticleService.swift'); process.exit(1); }
  const body = match[1];
  // Swift multi-line literals drop the closing delimiter's indentation.
  const lines = body.split('\n');
  const indent = Math.min.apply(null, lines.filter(l => l.trim()).map(l => l.length - l.trimStart().length));
  const js = lines.map(l => (l.trim() ? l.slice(indent) : l)).join('\n');
  return js.replace('\\(planJSON)', JSON.stringify(PLAN));
}

// The plan SpeechLogic's ReaderModeExtraction produces (see
// Packages/SpeechLogic/Sources/SpeechLogic/ReaderModeExtraction.swift).
const PLAN = {
  stripSelectors: [
    'nav', 'footer', '#footer', '.footer', '#sidebar', '.sidebar',
    '.navigation', '.nav', '.menu', '.mw-sidebar', '.mw-portlet',
    '.portal', '#mw-navigation', '#siteSub', '#p-navigation',
    'input', 'textarea', 'form', 'button', 'select'
  ],
  articleRootSelectors: [
    'article', 'main', '[role="main"]', '.post-content', '.entry-content',
    '.article-content', '.article-body', '.story-body'
  ],
  minArticleChars: 400
};

// ---- mock DOM ----------------------------------------------------------
// One element model serves both the extraction script and the real
// markdown walker: nodeType, nodeName, childNodes, nodeValue,
// getAttribute, hasAttribute, textContent (walker) and querySelectorAll
// / cloneNode / parentNode (extraction).
function text(s) {
  return {
    nodeType: 3,
    nodeValue: s,
    childNodes: [],
    cloneNode() { return text(s); }
  };
}

function el(name, attrs = {}, ...children) {
  const node = {
    nodeType: 1,
    nodeName: name.toUpperCase(),
    tagName: name.toUpperCase(),
    attrs,
    childNodes: children,
    parentNode: null,
    getAttribute(n) { const v = this.attrs[n]; return v === undefined ? null : v; },
    hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n); },
    get textContent() {
      return this.childNodes.map(c => (c.nodeType === 3 ? c.nodeValue : c.textContent)).join('');
    },
    get innerText() { return this.textContent; },
    querySelectorAll(selector) {
      const wanted = selector.trim().toLowerCase();
      const out = [];
      const matches = (n) => {
        const tag = (n.nodeName || '').toLowerCase();
        if (wanted.startsWith('#')) return n.attrs && n.attrs.id === wanted.slice(1);
        if (wanted.startsWith('.')) return n.attrs && (n.attrs.class || '').split(/\s+/).includes(wanted.slice(1));
        if (wanted.startsWith('[')) {
          const m = wanted.match(/^\[([a-z-]+)=["']?([^"'\]]+)["']?\]$/);
          return m ? (n.attrs && n.attrs[m[1]] === m[2]) : false;
        }
        return tag === wanted;
      };
      const walk = (n) => {
        for (const child of n.childNodes || []) {
          if (child.nodeType !== 1) continue;
          if (matches(child)) out.push(child);
          walk(child);
        }
      };
      walk(this);
      return out;
    },
    querySelector(selector) {
      const all = this.querySelectorAll(selector);
      return all.length ? all[0] : null;
    },
    cloneNode() {
      const copy = el(this.nodeName.toLowerCase(), Object.assign({}, this.attrs), ...this.childNodes.map(c => c.cloneNode()));
      return copy;
    },
    removeChild(child) {
      const idx = this.childNodes.indexOf(child);
      if (idx < 0) throw new Error('removeChild: not a child');
      this.childNodes.splice(idx, 1);
      child.parentNode = null;
      return child;
    },
    remove() {
      if (this.parentNode) {
        const idx = this.parentNode.childNodes.indexOf(this);
        if (idx >= 0) this.parentNode.childNodes.splice(idx, 1);
        this.parentNode = null;
      }
    }
  };
  for (const child of children) { if (child && typeof child === 'object') child.parentNode = node; }
  return node;
}

function textNodeClone() { return { nodeType: 3, nodeValue: this.nodeValue, childNodes: [], cloneNode() { return textNodeClone.call(this); } }; }
text.nodeType = 3;

// The walker wants `text()` nodes with cloneNode? It does not clone them,
// but the extraction script clones whole trees — so text nodes need one.
function cloneText(s) { return { nodeType: 3, nodeValue: s, childNodes: [], cloneNode() { return cloneText(s); } }; }

function makeDocument(root, meta = {}, title = 'The Headline') {
  const doc = {
    nodeType: 9,
    title,
    baseURI: 'https://example.com/story',
    childNodes: [root],
    querySelector(selector) {
      const s = selector.trim();
      if (s.startsWith('meta[')) {
        const m = s.match(/^meta\[(name|property)="([^"]+)"\]$/);
        if (!m) return null;
        const value = meta[m[1] + ':' + m[2]];
        if (value === undefined) return null;
        const node = el('meta', { content: value });
        node.getAttribute = function (n) { return n === 'content' ? value : null; };
        return node;
      }
      return root.querySelector(s);
    },
    querySelectorAll(selector) { return root.querySelectorAll(selector); },
    cloneNode() {
      const copy = el('html', {}, ...root.childNodes.map(c => (c.nodeType === 3 ? cloneText(c.nodeValue) : c.cloneNode())));
      return copy;
    }
  };
  return doc;
}

// ---- run the extraction script -----------------------------------------
function runExtraction(document) {
  const sandbox = {
    document,
    console,
    JSON,
    String,
    Array,
    Math,
    DOMParser: function () {
      this.parseFromString = function (html) {
        return { documentElement: el('div', {}, text(html)) };
      };
    },
    Readability: function (clone, options) {
      // A stand-in for Mozilla's scorer: it reads the clone's text and
      // hands back a "parsed" shape. The harness only cares that the
      // SCORED path is reached with the chrome already stripped.
      this.parse = function () {
        const body = clone.querySelector('body') || clone;
        const content = body.querySelector('article') || body;
        return {
          title: document.title,
          byline: '',
          siteName: '',
          excerpt: '',
          textContent: content.textContent,
          content: content
        };
      };
    }
  };
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(WALKER, 'utf8'), sandbox);
  // The script's last statement is the IIFE, so the completion value of
  // the script IS the JSON string it returns.
  const out = vm.runInContext(extractScript(), sandbox);
  return typeof out === 'string' ? JSON.parse(out) : out;
}

// ---- assertions --------------------------------------------------------
let pass = 0, fail = 0;
function check(label, actual, expected) {
  if (actual === expected) { pass++; console.log(`  ok  ${label}`); }
  else {
    fail++;
    console.log(`FAIL  ${label}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  }
}

function longText(n) { return 'The story continues here. '.repeat(Math.ceil(n / 24)).slice(0, n); }

// 1. The fast path takes the <article>, and the nav/footer around it
//    never reach the markdown.
{
  const article = el('article', {},
    el('h1', {}, text('The Headline')),
    el('p', {}, text(longText(500))),
    el('p', {}, text('And a second paragraph of the story.')));
  const nav = el('nav', {}, el('a', { href: '/x' }, text('Home')));
  const footer = el('footer', {}, text('Copyright'));
  const body = el('body', {}, nav, article, footer);
  const doc = makeDocument(body, { 'property:og:title': 'The Headline' }, 'The Headline');
  const out = runExtraction(doc);
  check('the fast path succeeds', out.ok, true);
  check('the fast path is marked as markdown-only', out.textFromMarkdown, true);
  check('the nav never reaches the article', out.markdown.includes('Home'), false);
  check('the footer never reaches the article', out.markdown.includes('Copyright'), false);
  check('the story is in the markdown', out.markdown.includes('The story continues here.'), true);
  check('the headline is not repeated', out.markdown.startsWith('The story continues here.'), true);
  check('the title comes from og:title', out.title, 'The Headline');
  check('the excerpt is the first 100 chars', out.excerpt.length, 100);
}

// 2. A page with no article root falls through to the scored path.
{
  const body = el('body', {},
    el('div', { class: 'post' }, el('p', {}, text(longText(500)))),
    el('nav', {}, text('Menu')));
  const doc = makeDocument(body, {}, 'No Article Root');
  const out = runExtraction(doc);
  check('a page without an article root still imports', out.ok, true);
  check('a page without an article root is not markdown-only', !!out.textFromMarkdown, false);
}

// 3. A STUB article (too little text) must not win — the NEXT candidate
//    does, and the stub's text never reaches the article.
{
  const stub = el('article', {}, el('p', {}, text('Related posts')));
  const real = el('div', { class: 'entry-content' }, el('p', {}, text(longText(500))));
  const body = el('body', {}, stub, real);
  const doc = makeDocument(body, {}, 'Stub First');
  const out = runExtraction(doc);
  check('the stub article is skipped', out.markdown.includes('Related posts'), false);
  check('the real story is taken instead', out.markdown.includes('The story continues here.'), true);
}

// 4. A class-named content root takes the fast path too.
{
  const body = el('body', {},
    el('div', { class: 'post-content' }, el('p', {}, text(longText(500)))),
    el('nav', {}, text('Menu')));
  const doc = makeDocument(body, {}, 'Class Named Root');
  const out = runExtraction(doc);
  check('a class-named content root takes the fast path', out.textFromMarkdown, true);
  check('the nav never reaches it', out.markdown.includes('Menu'), false);
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
