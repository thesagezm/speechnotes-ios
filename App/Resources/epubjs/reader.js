// reader.js — the native <-> epub.js glue (ours, see LICENSE-NOTES.md).
// Loads the EPUB from the bookscheme:// scheme handler into epub.js, renders
// ONE chapter at a time in scrolled flow (chapter boundaries are the app's
// memory bounds and TTS units), and reports position/TOC back to SwiftUI.
// Initial theme/fontSize arrive as query params — applying them later via
// evaluateJavaScript would race the rendition's creation.
(function () {
  var params = new URLSearchParams(location.search);
  // RELATIVE path under the shell origin — a fetch to a DIFFERENT custom
  // scheme host is cross-origin between opaque origins and WebKit blocks it.
  var bookPath = params.get("bookPath");
  var startChapter = parseInt(params.get("chapter") || "0", 10);
  var startTheme = params.get("theme") || "light";
  var startFontSize = parseInt(params.get("fontSize") || "100", 10);

  var THEMES = {
    light: { body: { background: "#ffffff", color: "#1a1a1a" } },
    sepia: { body: { background: "#f6efe2", color: "#3b3128" } },
    dark: { body: { background: "#121212", color: "#d8d4cf" } }
  };

  function post(msg) {
    try { webkit.messageHandlers.reader.postMessage(msg); } catch (e) { /* no native side */ }
  }

  // epub.js computes location.start.percentage from generated locations —
  // we deliberately skip locations.generate() (it renders the whole book),
  // so percentage is always 0/undefined here (v1.4.2 BUG B). The scrolled
  // flow instead reports which viewport-height chunk of the CURRENT chapter
  // is visible as start.displayed.page/total — a chapter-local fraction for
  // free. A chapter shorter than one viewport reports total <= 1 → 0%.
  function relocatedFraction(location) {
    var start = location && location.start;
    if (start && typeof start.percentage === "number" && start.percentage > 0) {
      return start.percentage;
    }
    if (start && start.displayed && start.displayed.total > 1) {
      var page = start.displayed.page || 1;
      var fraction = (page - 1) / (start.displayed.total - 1);
      return Math.min(Math.max(fraction, 0), 1);
    }
    return 0;
  }

  function applyFontSize(pct) {
    if (window.RENDITION) window.RENDITION.themes.fontSize(pct + "%");
  }

  function applyTheme(mode) {
    if (!window.RENDITION) return;
    Object.keys(THEMES).forEach(function (key) {
      window.RENDITION.themes.register(key, THEMES[key]);
    });
    window.RENDITION.themes.select(mode);
    // The scroll container's background must match or edges flash white.
    document.body.style.background =
      THEMES[mode] ? THEMES[mode].body.background : "#ffffff";
  }

  // fetch first; XHR as the belt-and-braces fallback (both go through the
  // native WKURLSchemeHandler on modern WebKit).
  function fetchBook(path) {
    return fetch(path).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.arrayBuffer();
    }).catch(function (fetchErr) {
      return new Promise(function (resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", path, true);
        xhr.responseType = "arraybuffer";
        xhr.onload = function () {
          if (xhr.status === 200) resolve(xhr.response);
          else reject(new Error("XHR " + xhr.status + " (fetch said: " + fetchErr + ")"));
        };
        xhr.onerror = function () { reject(fetchErr); };
        xhr.send();
      });
    });
  }

  fetchBook(bookPath)
    .then(function (buf) {
      var book = ePub(buf);
      window.BOOK = book;
      var rendition = book.renderTo("viewer", {
        width: "100%",
        height: "100%",
        flow: "scrolled",
        spread: "none",
        allowScriptedContent: true
      });
      window.RENDITION = rendition;
      applyTheme(startTheme);
      applyFontSize(startFontSize);

      rendition.on("relocated", function (location) {
        var start = location && location.start;
        post({
          type: "relocated",
          index: start && typeof start.index === "number" ? start.index : 0,
          fraction: relocatedFraction(location),
          // epub.js hands us a stable CFI per relocation — the app persists
          // it so reopening restores mid-chapter position even after a
          // font-size change or rotation (the old chapterIndex+fraction
          // only ever got you back to the top of the chapter).
          cfi: (start && start.cfi) || null,
          total: book.spine ? book.spine.length : 0
        });
      });

      book.loaded.navigation.then(function (nav) {
        var flat = [];
        function walk(items) {
          (items || []).forEach(function (item) {
            var label = (item.label || "").replace(/\s+/g, " ").trim();
            if (label && item.href) flat.push({ label: label, href: item.href });
            walk(item.subitems);
          });
        }
        walk(nav.toc);
        post({ type: "toc", items: flat });
      });

      // Display once the container is open — displaying earlier races
      // spine parsing on big books.
      book.opened.then(function () {
        // A saved CFI wins over the chapter index: the app persists CFI on
        // relocation, so reopening restores mid-chapter; fall back to the
        // chapter index on first open / legacy data / unrenderable CFI.
        var initialCfi = params.get("cfi");
        if (initialCfi) {
          rendition.display(initialCfi).catch(function () {
            var fallback = book.spine.get(startChapter);
            rendition.display(fallback ? fallback.href : undefined);
          });
          return;
        }
        var target = book.spine.get(startChapter);
        rendition.display(target ? target.href : undefined);
      });
    })
    .catch(function (err) {
      post({ type: "error", message: String(err) });
    });

  // --- native -> reader commands (called via evaluateJavaScript) ---

  window.readerGoToHref = function (href) {
    if (window.RENDITION && href) window.RENDITION.display(href);
  };

  window.readerGoChapter = function (index) {
    if (!window.BOOK || !window.RENDITION) return;
    var item = window.BOOK.spine.get(index);
    if (item) window.RENDITION.display(item.href);
  };

  window.readerFontSize = applyFontSize;

  window.readerTheme = applyTheme;

  window.readerDestroy = function () {
    try { if (window.RENDITION) window.RENDITION.destroy(); } catch (e) { /* already gone */ }
    try { if (window.BOOK) window.BOOK.destroy(); } catch (e) { /* already gone */ }
    window.RENDITION = null;
    window.BOOK = null;
  };
})();
