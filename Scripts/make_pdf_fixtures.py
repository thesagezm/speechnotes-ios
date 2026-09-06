#!/usr/bin/env python3
"""Generates the minimal PDF fixtures used by SpeechLogicTests/PdfTests.

Hand-assembled PDF 1.4 (no deps): objects dict -> bytes with a computed xref
table, Helvetica text runs, ASCII-only content. Three shapes the tests rely on:

  pdf-outline.pdf   3 pages + /Outlines with 3 top-level items (pages 1..3),
                    one nested child under item 2 (must NOT become a chapter).
  pdf-headings.pdf  3 pages, NO outline; 20pt heading lines vs 11pt body —
                    drives the line-height heading fallback.
  pdf-columns.pdf   1 page, two text columns; RIGHT column is drawn FIRST so
                    content order != reading order (extraction must fix it).

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


if __name__ == "__main__":
    os.makedirs(FIXTURE_DIR, exist_ok=True)
    build_outline_fixture()
    build_headings_fixture()
    build_columns_fixture()
    build_blank_fixture()
