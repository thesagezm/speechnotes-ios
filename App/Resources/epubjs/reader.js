// reader.js — the native <-> epub.js glue (ours, see LICENSE-NOTES.md).
// Loads the EPUB from the bookscheme:// scheme handler into epub.js, renders
// ONE chapter at a time (scrolled or paginated flow — chapter boundaries are
// the app's memory bounds and TTS units), and reports position/TOC back to
// SwiftUI. Initial appearance arrives as query params — applying it later
// via evaluateJavaScript would race the rendition's creation. Later changes
// ride the readerAppearance({...}) bridge command.
(function () {
  var params = new URLSearchParams(location.search);
  // RELATIVE path under the shell origin — a fetch to a DIFFERENT custom
  // scheme host is cross-origin between opaque origins and WebKit blocks it.
  var bookPath = params.get("bookPath");
  var startChapter = parseInt(params.get("chapter") || "0", 10);

  var STATE = {
    theme: params.get("theme") || "light",
    fontSize: parseInt(params.get("fontSize") || "100", 10),
    flow: params.get("flow") || "scrolled",
    font: params.get("font") || "book",
    lineHeight: parseFloat(params.get("lineHeight") || "1.6"),
    paraSpacing: parseFloat(params.get("paraSpacing") || "0"),
    letterSpacing: parseFloat(params.get("letterSpacing") || "0"),
    padding: parseInt(params.get("padding") || "16", 10),
    respectStyles: params.get("respectStyles") === "1",
    // Page-turn interaction (Anx-style choice): tap left/right thirds turn
    // pages, the middle toggles chrome; swipe turns pages. Both act in
    // PAGINATED flow only (scrolled flow is native scrolling). Both default
    // ON, invert swaps the tap sides for RTL readers.
    tapTurn: params.get("tapTurn") !== "0",
    swipeTurn: params.get("swipeTurn") !== "0",
    tapInverted: params.get("tapInv") === "1",
    // Where auto-scroll's chapter-advance resumes from — updated on every
    // relocation so a manual jump keeps advancing from the right place.
    spineIndex: startChapter
  };

  var THEMES = {
    light: { background: "#ffffff", color: "#1a1a1a" },
    sepia: { background: "#f6efe2", color: "#3b3128" },
    dark: { background: "#121212", color: "#d8d4cf" },
    trueBlack: { background: "#000000", color: "#c9c9c9" }
  };

  var FONTS = {
    serif: 'Georgia, "Iowan Old Style", "Palatino", serif',
    sans: '-apple-system, "Helvetica Neue", Arial, sans-serif',
    mono: '"SF Mono", Menlo, Consolas, monospace'
  };

  function post(msg) {
    try { webkit.messageHandlers.reader.postMessage(msg); } catch (e) { /* no native side */ }
  }

  // epub.js computes location.start.percentage from generated locations —
  // we deliberately skip locations.generate() (it renders the whole book),
  // so percentage is always 0/undefined here (v1.4.2 BUG B). Both flows
  // report which page/chunk of the CURRENT chapter is visible as
  // start.displayed.page/total — a chapter-local fraction for free. A
  // chapter shorter than one viewport reports total <= 1 → 0%.
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

  // --- appearance -------------------------------------------------------
  // One merged rule set (theme colors + typography) registered and selected
  // in one call — the same register+select pattern the old per-theme
  // applyTheme used, proven to update live in this webview.
  function applyAppearance() {
    var colors = THEMES[STATE.theme] || THEMES.light;
    var rules = {
      body: {
        background: colors.background,
        color: colors.color
      }
    };
    if (!STATE.respectStyles) {
      if (FONTS[STATE.font]) rules.body["font-family"] = FONTS[STATE.font];
      rules.body["line-height"] = STATE.lineHeight;
      if (STATE.letterSpacing > 0) rules.body["letter-spacing"] = STATE.letterSpacing + "px";
      // Zero paraSpacing adds no rule — the book's own paragraph rhythm
      // survives untouched unless the user actually opens the slider.
      if (STATE.paraSpacing > 0) {
        rules.p = { margin: "0 0 " + STATE.paraSpacing + "em" };
      }
    }
    if (window.RENDITION) {
      window.RENDITION.themes.register("sn", rules);
      window.RENDITION.themes.select("sn");
    }
    // The scroll container's background must match or edges flash white.
    document.body.style.background = colors.background;
    applyPadding();
  }

  function applyPadding() {
    var v = document.getElementById("viewer");
    if (!v) return;
    // Paginated column widths are measured off the container — padding
    // there breaks the column math, so margins are scrolled-only.
    v.style.padding = STATE.flow === "paginated" ? "0" : STATE.padding + "px";
  }

  // --- auto-scroll (scrolled flow) ---------------------------------------
  // A hands-free teleprompter: rAF-driven scroll of whichever element is
  // actually scrolling (usually the shell document; epub.js may hand the
  // scroll to the section iframe). At a chapter's bottom it advances to the
  // next spine item and keeps rolling; the dwell guard keeps books with
  // tiny chapters from fast-forwarding out of control.
  var AUTO = { on: false, speed: 40, last: 0, raf: 0, lastAdvance: 0 };

  function findScroller() {
    var se = document.scrollingElement;
    if (se && se.scrollHeight > se.clientHeight + 4) return se;
    var view = window.RENDITION && window.RENDITION.views && window.RENDITION.views.current
      ? window.RENDITION.views.current() : null;
    var doc = view && view.document;
    if (doc) {
      var de = doc.documentElement;
      if (de && de.scrollHeight > de.clientHeight + 4) return de;
      if (doc.body && doc.body.scrollHeight > doc.body.clientHeight + 4) return doc.body;
    }
    return se;
  }

  function advanceChapter() {
    var now = performance.now();
    if (now - AUTO.lastAdvance < 800) return; // dwell guard
    AUTO.lastAdvance = now;
    if (!window.BOOK || !window.RENDITION) { stopAutoScroll(); return; }
    var next = window.BOOK.spine.get(STATE.spineIndex + 1);
    if (!next) { stopAutoScroll(); return; } // end of book — JS stops, native toggle stays
    AUTO.last = 0;
    window.RENDITION.display(next.href);
  }

  function autoScrollFrame(ts) {
    if (!AUTO.on) return;
    if (AUTO.last) {
      var dt = Math.min((ts - AUTO.last) / 1000, 0.1);
      var sc = findScroller();
      if (sc) {
        var max = sc.scrollHeight - sc.clientHeight;
        if (max <= 4) {
          advanceChapter(); // chapter fits one screen — move on
        } else if (sc.scrollTop >= max - 2) {
          advanceChapter();
        } else {
          sc.scrollTop += AUTO.speed * dt;
        }
      }
    }
    AUTO.last = ts;
    AUTO.raf = requestAnimationFrame(autoScrollFrame);
  }

  function stopAutoScroll() {
    AUTO.on = false;
    if (AUTO.raf) cancelAnimationFrame(AUTO.raf);
    AUTO.raf = 0;
    AUTO.last = 0;
  }

  // --- book load ---------------------------------------------------------

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
        flow: STATE.flow,
        spread: "none",
        allowScriptedContent: true
      });
      window.RENDITION = rendition;
      applyAppearance();

      // Chrome taps and (paginated) page-turn swipes: every rendered
      // section's iframe document gets the listeners (see attachGestures
      // below the destroy() wiring).
      rendition.on("rendered", function (section, view) {
        attachGestures(view);
      });

      rendition.on("relocated", function (location) {
        var start = location && location.start;
        if (start && typeof start.index === "number") STATE.spineIndex = start.index;
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

  // Paginated page turns (swipe gesture relay). epub.js crosses spine
  // boundaries on its own in paginated flow.
  window.readerNext = function () {
    if (window.RENDITION) window.RENDITION.next();
  };
  window.readerPrev = function () {
    if (window.RENDITION) window.RENDITION.prev();
  };

  // Live appearance push — the JSON body mirrors the ReaderAppearance
  // struct. autoScroll fields are driven by the dedicated commands below.
  window.readerAppearance = function (json) {
    if (!json) return;
    var a = typeof json === "string" ? JSON.parse(json) : json;
    if (a.theme) STATE.theme = a.theme;
    if (typeof a.fontSize === "number") STATE.fontSize = a.fontSize;
    if (a.font) STATE.font = a.font;
    if (typeof a.lineHeight === "number") STATE.lineHeight = a.lineHeight;
    if (typeof a.paraSpacing === "number") STATE.paraSpacing = a.paraSpacing;
    if (typeof a.letterSpacing === "number") STATE.letterSpacing = a.letterSpacing;
    if (typeof a.margin === "number") STATE.padding = a.margin;
    if (typeof a.respectStyles === "boolean") STATE.respectStyles = a.respectStyles;
    // Page-turn interaction — booleans, so presence checks must be typeof
    // (a false value still has to land).
    if (typeof a.tapTurn === "boolean") STATE.tapTurn = a.tapTurn;
    if (typeof a.swipeTurn === "boolean") STATE.swipeTurn = a.swipeTurn;
    if (typeof a.tapInverted === "boolean") STATE.tapInverted = a.tapInverted;
    applyAppearance();
  };

  // Back-compat shims (older callers / debugging).
  window.readerFontSize = function (pct) {
    if (typeof pct === "number") { STATE.fontSize = pct; applyAppearance(); }
  };
  window.readerTheme = function (mode) {
    if (mode) { STATE.theme = mode; applyAppearance(); }
  };

  window.readerAutoScroll = function (on, speed) {
    if (typeof speed === "number" && speed > 0) AUTO.speed = speed;
    if (on && !AUTO.on) {
      AUTO.on = true;
      AUTO.last = 0;
      AUTO.raf = requestAnimationFrame(autoScrollFrame);
    } else if (!on && AUTO.on) {
      stopAutoScroll();
    }
  };

  window.readerAutoScrollSpeed = function (speed) {
    if (typeof speed === "number" && speed > 0) AUTO.speed = speed;
  };

  window.readerDestroy = function () {
    stopAutoScroll();
    try { if (window.RENDITION) window.RENDITION.destroy(); } catch (e) { /* already gone */ }
    try { if (window.BOOK) window.BOOK.destroy(); } catch (e) { /* already gone */ }
    window.RENDITION = null;
    window.BOOK = null;
  };

  // --- gestures inside the book iframes ---
  // Book content lives INSIDE epub.js iframes, so listeners on the shell
  // document never see page touches — the round-6 report: tap-to-hide dead
  // in both orientations. Every rendered section's document gets its own
  // listeners, which relay to the shell via postMessage (same origin), and
  // the shell forwards to the native message channel. Taps on links and
  // text selections stay out of the toggle; swipes only fire in paginated
  // flow (scrolled swiping is native scrolling).
  function attachGestures(view) {
    var doc = view && view.document;
    if (!doc) return;
    doc.addEventListener("click", function (event) {
      var node = event.target;
      while (node && node !== doc) {
        if (node.tagName === "A") return;
        node = node.parentElement;
      }
      var sel = doc.getSelection && doc.getSelection();
      if (sel && !sel.isCollapsed && String(sel).length > 0) return;
      // Paginated + tap zones ON: the left third turns back, the right
      // third turns forward, the MIDDLE is the chrome toggle (Anx's
      // layout). Anything else — scrolled flow, tap zones off — keeps the
      // historical whole-surface chrome toggle.
      if (STATE.flow === "paginated" && STATE.tapTurn) {
        var width = (doc.documentElement && doc.documentElement.clientWidth) || doc.body.clientWidth || 0;
        if (width > 0) {
          var x = event.clientX;
          var leftZone = x < width / 3;
          var rightZone = x > (width * 2) / 3;
          if (leftZone || rightZone) {
            var turnNext = STATE.tapInverted ? leftZone : rightZone;
            try { window.parent.postMessage({ speechnotes: "pageTurn", dir: turnNext ? "next" : "prev" }, "*"); } catch (e) { /* blocked */ }
            return;
          }
        }
      }
      try { window.parent.postMessage({ speechnotes: "chromeTap" }, "*"); } catch (e) { /* blocked */ }
    }, false);

    var touch = { x: 0, y: 0, t: 0 };
    doc.addEventListener("touchstart", function (event) {
      var t = event.changedTouches[0];
      if (t) { touch.x = t.clientX; touch.y = t.clientY; touch.t = Date.now(); }
    }, { passive: true });
    doc.addEventListener("touchend", function (event) {
      if (STATE.flow !== "paginated") return;
      if (!STATE.swipeTurn) return;
      var t = event.changedTouches[0];
      if (!t) return;
      var dx = t.clientX - touch.x;
      var dy = t.clientY - touch.y;
      if (Date.now() - touch.t > 600) return;
      if (Math.abs(dx) < 60 || Math.abs(dy) > 50) return;
      var sel = doc.getSelection && doc.getSelection();
      if (sel && !sel.isCollapsed && String(sel).length > 0) return;
      try {
        window.parent.postMessage({ speechnotes: "pageTurn", dir: dx < 0 ? "next" : "prev" }, "*");
      } catch (e) { /* blocked */ }
    }, { passive: true });
  }

  window.addEventListener("message", function (event) {
    if (!event.data) return;
    if (event.data.speechnotes === "chromeTap") {
      post({ type: "chromeTap" });
    } else if (event.data.speechnotes === "pageTurn") {
      // Tap zones AND swipes both land here — the native side runs the
      // same rendition.next()/prev() for either.
      post({ type: "pageTurn", dir: event.data.dir === "prev" ? "prev" : "next" });
    }
  }, false);
})();
