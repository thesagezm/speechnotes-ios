#!/usr/bin/env python3
"""Generates the minimal PDF fixtures used by SpeechLogicTests/PdfTests.

Hand-assembled PDF 1.4 (no deps): objects dict -> bytes with a computed xref
table, Helvetica text runs, ASCII-only content. Shapes the tests rely on:

  pdf-outline.pdf   3 pages + /Outlines with 3 top-level items (pages 1..3),
                    one nested child under item 2 (must NOT become a chapter).
  pdf-headings.pdf  3 pages, NO outline; 20pt heading lines vs 11pt body —
                    drives the line-height heading fallback.
  pdf-columns.pdf   1 page, two text columns; RIGHT column is drawn FIRST so
                    content order != reading order (extraction must fix it).
  pdf-blank.pdf     1 page, no text runs — the scanned-PDF shape (OCR routing).
  pdf-watermark.pdf 4 pages whose ENTIRE text layer is "Scanned by CamScanner"
                    — the CamScanner scan that read as three words. The scan
                    detector must call it a scan.
  pdf-prose.pdf     4 pages of real prose — the control case (NOT a scan).
  pdf-thin.pdf      4 pages of short but distinct paragraphs — a running
                    head, not a watermark (NOT a scan).

Run from repo root:  python3 Scripts/make_pdf_fixtures.py
"""

import os

FIXTURE_DIR = os.path.join(
    os.path.dirname(__file__), "..", "Packages", "SpeechLogic", "Tests", "SpeechLogicTests", "Fixtures"
)


class PdfBuilder:
    """Minimal PDF writer: numbered objects -> bytes with a correct xref."""

    def __init__(self):
        self.objects = {}

    def reserve(self) -> int:
        num = max(self.objects.keys(), default=0) + 1
        self.objects[num] = b"<< /Reserved >>"
        return num

    def set(self, num: int, body: bytes):
        self.objects[num] = body

    def add(self, body: bytes) -> int:
        num = self.reserve()
        self.set(num, body)
        return num

    def stream(self, content: bytes) -> int:
        return self.add(
            b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n"
            + content + b"\nendstream"
        )

    def build(self, root: int) -> bytes:
        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = {}
        for num in sorted(self.objects):
            offsets[num] = len(out)
            out += str(num).encode() + b" 0 obj\n" + self.objects[num] + b"\nendobj\n"
        xref_pos = len(out)
        count = max(self.objects) + 1
        out += b"xref\n0 " + str(count).encode() + b"\n"
        out += b"0000000000 65535 f \n"
        for i in range(1, count):
            if i in offsets:
                out += ("%010d 00000 n \n" % offsets[i]).encode()
            else:
                out += b"0000000000 65535 f \n"
        out += (
            b"trailer\n<< /Size " + str(count).encode() + b" /Root " + str(root).encode()
            + b" 0 R >>\nstartxref\n" + str(xref_pos).encode() + b"\n%%EOF\n"
        )
        return bytes(out)


def text_ops(lines, x, top_y, leading, size=11):
    """Absolute-positioned one-line BT/ET blocks — one text box per line."""
    ops = []
    for i, line in enumerate(lines):
        y = top_y - i * leading
        raw = line if isinstance(line, bytes) else line.encode()
        ops.append(
            b"BT /F1 " + str(size).encode() + b" Tf 1 0 0 1 "
            + str(x).encode() + b" " + str(y).encode() + b" Tm ("
            + raw + b") Tj ET"
        )
    return b"\n".join(ops)


def make_page(b, content, font, pages, no_font=False):
    stream = b.stream(content)
    fonts = b"" if no_font else b" /Resources << /Font << /F1 " + str(font).encode() + b" 0 R >> >>"
    return b.add(
        b"<< /Type /Page /Parent " + str(pages).encode()
        + b" 0 R /MediaBox [0 0 612 792]" + fonts
        + b" /Contents " + str(stream).encode() + b" 0 R >>"
    )


def write(name, data):
    path = os.path.join(FIXTURE_DIR, name)
    with open(path, "wb") as fh:
        fh.write(data)
    print("wrote", os.path.normpath(path), len(data), "bytes")


def build_outline_fixture():
    b = PdfBuilder()
    font = b.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = b.reserve()
    outlines = b.reserve()
    n1, n2, n3, child = b.reserve(), b.reserve(), b.reserve(), b.reserve()

    p1 = make_page(b, text_ops([b"This is chapter one.", b"Body text for chapter one."], 72, 720, 18), font, pages)
    p2 = make_page(b, text_ops([b"This is chapter two.", b"Body text for chapter two."], 72, 720, 18), font, pages)
    p3 = make_page(b, text_ops([b"This is chapter three."], 72, 720, 18), font, pages)

    b.set(n1, b"<< /Title (Chapter One) /Parent " + str(outlines).encode() + b" 0 R /Next "
        + str(n2).encode() + b" 0 R /Dest [" + str(p1).encode() + b" 0 R /XYZ 0 792 null] >>")
    # Chapter Two swallows its child: a parent with its own destination must
    # contribute ONE chapter start and NOT also emit its children.
    b.set(n2, b"<< /Title (Chapter Two) /Parent " + str(outlines).encode() + b" 0 R /Prev "
        + str(n1).encode() + b" 0 R /Next " + str(n3).encode() + b" 0 R /First "
        + str(child).encode() + b" 0 R /Last " + str(child).encode() + b" 0 R /Count 1 /Dest ["
        + str(p2).encode() + b" 0 R /XYZ 0 792 null] >>")
    b.set(n3, b"<< /Title (Chapter Three) /Parent " + str(outlines).encode() + b" 0 R /Prev "
        + str(n2).encode() + b" 0 R /Dest [" + str(p3).encode() + b" 0 R /XYZ 0 792 null] >>")
    b.set(child, b"<< /Title (Section 2.1) /Parent " + str(n2).encode() + b" 0 R /Dest ["
        + str(p2).encode() + b" 0 R /XYZ 0 700 null] >>")
    b.set(outlines, b"<< /Type /Outlines /First " + str(n1).encode() + b" 0 R /Last "
        + str(n3).encode() + b" 0 R /Count 3 >>")
    b.set(pages, b"<< /Type /Pages /Kids [" + str(p1).encode() + b" 0 R "
        + str(p2).encode() + b" 0 R " + str(p3).encode() + b" 0 R] /Count 3 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R /Outlines "
        + str(outlines).encode() + b" 0 R >>")
    write("pdf-outline.pdf", b.build(catalog))


def build_headings_fixture():
    b = PdfBuilder()
    font = b.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = b.reserve()

    p1 = make_page(b, text_ops([b"First Chapter"], 72, 720, 26, size=20) + b"\n"
        + text_ops([b"Body one point one.", b"Body one point two.", b"Body one point three."], 72, 650, 16), font, pages)
    p2 = make_page(b, text_ops([b"Second Chapter"], 72, 720, 26, size=20) + b"\n"
        + text_ops([b"Body two point one.", b"Body two point two.", b"Body two point three."], 72, 650, 16), font, pages)
    p3 = make_page(b, text_ops([b"Continuation body alpha.", b"Continuation body beta.",
        b"Continuation body gamma."], 72, 720, 16), font, pages)

    b.set(pages, b"<< /Type /Pages /Kids [" + str(p1).encode() + b" 0 R "
        + str(p2).encode() + b" 0 R " + str(p3).encode() + b" 0 R] /Count 3 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R >>")
    write("pdf-headings.pdf", b.build(catalog))


def build_columns_fixture():
    b = PdfBuilder()
    font = b.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = b.reserve()
    # RIGHT column drawn first: content order must not become reading order.
    content = text_ops([b"RIGHT-%d" % i for i in range(1, 6)], 330, 720, 24)
    content += b"\n" + text_ops([b"LEFT-%d" % i for i in range(1, 6)], 72, 720, 24)
    p1 = make_page(b, content, font, pages)
    b.set(pages, b"<< /Type /Pages /Kids [" + str(p1).encode() + b" 0 R] /Count 1 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R >>")
    write("pdf-columns.pdf", b.build(catalog))


def build_blank_fixture():
    """One page with NO text runs — the scanned-PDF shape (OCR routing)."""
    b = PdfBuilder()
    pages = b.reserve()
    p1 = make_page(b, b"", font=None, pages=pages, no_font=True)
    b.set(pages, b"<< /Type /Pages /Kids [" + str(p1).encode() + b" 0 R] /Count 1 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R >>")
    write("pdf-blank.pdf", b.build(catalog))


WATERMARK = b"Scanned by CamScanner"

# A real textbook paragraph: the text layer of a genuine text-layer PDF, long
# enough to clear the detector's 200-character prose bar with room to spare.
PROSE = [
    b"The history of paediatric cardiology begins with the recognition that",
    b"congenital heart disease is not a single diagnosis but a family of",
    b"conditions, each with its own haemodynamic signature and its own",
    b"natural history. Early descriptions were confined to post-mortem",
    b"findings, and it was not until the introduction of cardiac",
    b"catheterisation that clinicians could study the living circulation.",
    b"This chapter reviews the diagnostic reasoning that grew out of that",
    b"shift, and sets out the framework the rest of the book applies.",
]


def build_watermark_fixture():
    """CamScanner's shape: every page's WHOLE text layer is the watermark.

    The page has a real, invisible, selectable text layer — which is why the
    old "does this page have 16 characters" probe said YES, and the reader
    read the watermark out loud instead of the page. The detector must call
    this document a scan.
    """
    b = PdfBuilder()
    font = b.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = b.reserve()
    kids = [
        make_page(b, text_ops([WATERMARK], 72, 700, 18), font, pages)
        for _ in range(4)
    ]
    b.set(pages, b"<< /Type /Pages /Kids [" + b" ".join(f"{k} 0 R".encode() for k in kids)
        + b"] /Count 4 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R >>")
    write("pdf-watermark.pdf", b.build(catalog))


def build_prose_fixture():
    """A genuine text-layer document: dense prose on every page.

    The control case — the watermark detector must NOT send this to OCR.
    """
    b = PdfBuilder()
    font = b.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = b.reserve()
    kids = [
        make_page(b, text_ops(PROSE + [b"continued from the previous page."], 72, 740, 16), font, pages)
        for _ in range(4)
    ]
    b.set(pages, b"<< /Type /Pages /Kids [" + b" ".join(f"{k} 0 R".encode() for k in kids)
        + b"] /Count 4 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R >>")
    write("pdf-prose.pdf", b.build(catalog))


def build_thin_fixture():
    """A running head, not a watermark: every page carries a short but genuine
    paragraph. The pages differ from each other and each clears the prose
    bar, so the detector must NOT call this a scan — a page-count or
    character floor alone would."""
    b = PdfBuilder()
    font = b.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = b.reserve()
    kids = []
    for i in range(4):
        body = (
            b"Running head %d. " % i
            + b"This page carries a short but genuine paragraph of body text, "
            + b"long enough to be spoken and clearly the work of a real "
            + b"text layer rather than a scanner watermark left by an app."
        )
        kids.append(make_page(b, text_ops([body], 72, 700, 16), font, pages))
    b.set(pages, b"<< /Type /Pages /Kids [" + b" ".join(f"{k} 0 R".encode() for k in kids)
        + b"] /Count 4 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R >>")
    write("pdf-thin.pdf", b.build(catalog))


def build_mixed_fixture():
    """The mixed document: alternating real-text and watermark-only pages.

    Common in practice — a text PDF scanned by an app that stamps its
    watermark onto the pages it photographs, or a bundled workbook where
    only some pages are images. The document verdict says "not a scan" (half
    the pages have real prose), so the PER-PAGE test carries the odd pages:
    each watermark page must still be OCR'd, and each prose page must not.
    """
    b = PdfBuilder()
    font = b.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    pages = b.reserve()
    kids = []
    for i in range(6):
        if i % 2 == 0:
            kids.append(make_page(b, text_ops(PROSE, 72, 740, 16), font, pages))
        else:
            kids.append(make_page(b, text_ops([WATERMARK], 72, 700, 18), font, pages))
    b.set(pages, b"<< /Type /Pages /Kids [" + b" ".join(f"{k} 0 R".encode() for k in kids)
        + b"] /Count 6 >>")
    catalog = b.add(b"<< /Type /Catalog /Pages " + str(pages).encode() + b" 0 R >>")
    write("pdf-mixed.pdf", b.build(catalog))


if __name__ == "__main__":
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    build_outline_fixture()
    build_headings_fixture()
    build_columns_fixture()
    build_blank_fixture()
    build_watermark_fixture()
    build_prose_fixture()
    build_thin_fixture()
    build_mixed_fixture()
