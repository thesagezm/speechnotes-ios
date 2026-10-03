# Vendored third-party code in this folder

## engine.js, columns.js, symbols.js, texfonts.js, mathtext.js

From **papero-pdf-text-extractor** — <https://github.com/beatrizalmeidaf/papero-pdf-text-extractor>
(`web/assets/`), MIT licensed.

Taken as a snapshot of that project's browser build, with one change:
`engine.js` imported pdf.js from a CDN, which cannot work inside the app, so
the import now points at the local `./pdf.min.mjs` and the worker at
`./pdf.worker.min.mjs`.

The engine is a port of the project's own `src/papero_extract/layout.py` and
emits the same JSON (`schema: "pdf-text-api/document@1"`). Its layout
thresholds are named after their Python counterparts — **if you change one
here, change the same-named constant in `layout.py` upstream.** The parity
test in that repository (`tests/js/parity.mjs`) is what keeps the two honest.

What this vendored copy does NOT include, and cannot on the device: OCR
(Tesseract) and office-format support (Tika) are server-side parts of the
Python package. A scanned PDF therefore gets nothing here, and DOCX/PPTX/XLSX
keep the app's own reader. The app's built-in PDF path Vision-OCRs scans and
stays the fallback for them.

## pdf.min.mjs, pdf.worker.min.mjs

**pdf.js** 4.10.38, Apache License 2.0, © Mozilla Foundation and contributors.
<https://github.com/mozilla/pdf.js> — the full licence notice is preserved at
the top of `pdf.min.mjs`.

pinned version: 4.10.38 (the version papero's `engine.js` is written against)
