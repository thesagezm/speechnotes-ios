#!/usr/bin/env python3
"""A tiny static server for the foliate engine harness.

The harness drives the REAL iOS shell (App/Resources/foliatejs/sn-shell-ios.js)
over plain http in a browser, so the numbers it prints are the numbers the
shipped code path produces — not a re-implementation of it.

Routes:
  /                      the repo (so /App/Resources/foliatejs/*.js is reachable)
  /Scripts/foliate-harness/…   the harness page and its frame
  /files/<name>          the real book files (default: ~/Downloads)
  /files.json            the book listing the harness page fetches
  /save-report (POST)    the harness posts its JSON report here; it lands in
                          --out (default: Scripts/foliate-harness/report.json)

Usage:
  python3 -I Scripts/foliate-harness/serve.py [--port 8731] [--books ~/Downloads]
"""

import argparse
import json
import os
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# The formats the foliate shell dispatches on. .epub is deliberately absent:
# EPUBs never reach this shell — they stay on the epub.js reader.
BOOK_EXTS = {
    "mobi", "azw", "azw3", "prc", "pdb",
    "fb2", "rtf", "html", "htm", "htmlz",
    "txt", "md", "markdown",
}

MIME = {
    ".mobi": "application/x-mobipocket-ebook",
    ".azw": "application/vnd.amazon.ebook",
    ".azw3": "application/vnd.amazon.ebook",
    ".prc": "application/x-mobipocket-ebook",
    ".pdb": "application/vnd.palm",
    ".fb2": "application/x-fictionbook+xml",
    ".rtf": "application/rtf",
    ".html": "text/html; charset=utf-8",
    ".htm": "text/html; charset=utf-8",
    ".htmlz": "application/zip",
    ".txt": "text/plain; charset=utf-8",
    ".md": "text/markdown; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".html": "text/html; charset=utf-8",
}


class Handler(SimpleHTTPRequestHandler):
    books_dir = ""
    out_path = ""

    # -- routing ------------------------------------------------------------

    def translate_path(self, path):
        path = urllib.parse.unquote(path.split("?", 1)[0].split("#", 1)[0])
        parts = [p for p in path.split("/") if p and p not in (".", "..")]
        if parts and parts[0] == "files":
            return os.path.join(self.books_dir, *parts[1:])
        return os.path.join(ROOT, *parts)

    def guess_type(self, path):
        ext = os.path.splitext(path)[1].lower()
        if ext in MIME:
            return MIME[ext]
        if ext in BOOK_EXTS:
            return "application/octet-stream"
        return super().guess_type(path)

    def do_GET(self):
        route = urllib.parse.urlparse(self.path).path
        if route == "/files.json":
            self.send_json(self.book_listing())
            return
        super().do_GET()

    def do_POST(self):
        route = urllib.parse.urlparse(self.path).path
        if route != "/save-report":
            self.send_error(404, "unknown route")
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        try:
            payload = json.loads(body.decode("utf-8"))
        except Exception as exc:  # a malformed report is still worth saving raw
            payload = {"_unparsed": body.decode("utf-8", "replace"), "_error": str(exc)}
        with open(self.out_path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)
        self.send_json({"saved": self.out_path})

    # -- helpers ------------------------------------------------------------

    def send_json(self, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def book_listing(self):
        out = []
        try:
            names = sorted(os.listdir(self.books_dir))
        except OSError:
            return out
        for name in names:
            ext = os.path.splitext(name)[1].lstrip(".").lower()
            if ext not in BOOK_EXTS:
                continue
            if name.startswith("speechnotes-logs"):
                continue  # the app's own log file, not a book
            path = os.path.join(self.books_dir, name)
            if not os.path.isfile(path):
                continue
            out.append({
                "name": name,
                "format": ext,
                "size": os.path.getsize(path),
                "url": "/files/" + urllib.parse.quote(name),
            })
        return out

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass  # quiet: the harness output is the interesting part


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8731)
    ap.add_argument("--books", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--out", default=os.path.join(HERE, "report.json"))
    args = ap.parse_args()

    Handler.books_dir = os.path.abspath(os.path.expanduser(args.books))
    Handler.out_path = os.path.abspath(args.out)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"harness server: http://127.0.0.1:{args.port}/Scripts/foliate-harness/index.html")
    print(f"books: {Handler.books_dir}")
    print(f"report: {Handler.out_path}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
