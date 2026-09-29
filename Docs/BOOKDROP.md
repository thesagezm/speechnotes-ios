# BookDrop — LocalSend protocol receiver

BookDrop lets any LocalSend app (the desktop/mobile LocalSend client, Readest's
"Nearby BookDrop", another Speechnotes) push files to this device over the LAN.
The receiver needs no account, no cable, no cloud.

The iOS implementation lives in `App/Sources/Services/LocalSend/`:

| File | Role |
|---|---|
| `LocalSendModels.swift` | wire DTOs (device announce, prepare-upload, response) |
| `LocalSendHTTPServer.swift` | NWListener HTTP/1.1 server, port fallback, body spilling to disk, the loopback liveness probe |
| `LocalSendReceiver.swift` | endpoint logic, session state, sha256 verification, import routing |

This doc doubles as the porting brief for speechnotes-linux and
speechnotes-android — the protocol surface is identical, only the HTTP stack
and file plumbing differ.

## Protocol (v2.2) — receiver side

Spec: <https://github.com/localsend/protocol> (README.md = v2.2).

**Defaults**: TCP **53317** for HTTP, UDP 53317 group **224.0.0.167** for
multicast discovery. All ports are negotiable; LocalSend senders accept any
port the receiver announces.

### Discovery — the iOS-shaped part

A receiver does NOT need to announce anything:

- iOS has no multicast entitlement, and none is needed. LocalSend senders
  find peers by scanning the /24 subnet with **unicast** HTTP POSTs to
  `/api/localsend/v2/register`. As long as our HTTP server is up on the LAN,
  the sender finds us.
- We respond to `/register` with our device DTO. The sender then talks to us
  directly.

### Endpoints

| Method | Path | Meaning |
|---|---|---|
| POST | `/api/localsend/v2/register` | Discovery ping. Body = sender's device DTO. Respond 200 with OUR device DTO. |
| GET | `/api/localsend/v2/info` | Debug variant of register (also answered). |
| POST | `/api/localsend/v2/prepare-upload` | Sender offers files. Respond with sessionId + per-file tokens, or reject. |
| POST | `/api/localsend/v2/upload?sessionId&fileId&token` | Binary body, one file per request, parallel requests allowed. Respond 200 empty. |
| POST | `/api/localsend/v2/cancel?sessionId` | Sender aborts. Clean up. Respond 200. |

**Device DTO**

```json
{
  "alias": "iPhone",
  "version": "2.2",
  "deviceModel": null,
  "deviceType": "mobile",
  "fingerprint": "<stable-random>",
  "port": 53317,
  "protocol": "http",
  "download": false
}
```

Never hand-roll this in different places with different fields — Readest had
a bug where a missing `deviceType` made their phone show up as a "computer".

**prepare-upload request**

```json
{
  "info": { ...device DTO of the sender... },
  "pin": null,
  "files": {
    "<fileId>": {
      "id": "<fileId>",
      "fileName": "book.epub",
      "size": 123456,
      "fileType": "application/epub+zip",
      "sha256": "<hex|null>",
      "preview": null,
      "metadata": { "modified": null, "accessed": null }
    }
  }
}
```

**prepare-upload response 200** (partial accept = omit the ids you reject;
omitted ids count as rejected by the sender):

```json
{ "sessionId": "...", "files": { "<fileId>": "<token>" } }
```

Error codes: **403** rejected (or auto-accept off), **401** PIN
required/wrong (PIN is a `?pin=` query parameter on all three POSTs when
enabled), **409** another transfer in progress, **429** rate-limited,
**422** size/sha256 mismatch on upload.

### Session rules the senders rely on

- Validate `sessionId`, `fileId`, `token` AND the sender's IP on every
  upload — a third party on the LAN must not inject files into someone's
  session.
- `sha256` (when offered) verified → **422** on mismatch.
- Duplicate upload of one fileId → **409**.
- One active session at a time (ours) → **409** for a second prepare.
- Sessions time out (ours: 5 min) and clean their temp files.

## iOS-specific lessons (from Readest's PR #6049 — their repo documents this
bug in `apps/readest-app/.claude/memory/bookdrop-ios-zombie-listener.md`)

1. **The zombie listener.** When iOS suspends the app it may reclaim the
   listening socket while the accept loop hangs forever. The "running" flag
   stays true, the UI lies, and peers see nothing until the toggle is
   flipped manually. **Fix**: on every `didBecomeActive`, probe your own
   port with a 500 ms loopback TCP connect. If it fails: stop the server,
   then start it again — stop FIRST, because a start() that finds a
   still-registered listener returns the existing dead one.
2. **Backgrounding grace** is ~5–10 s: after the app suspends, peers may
   still see the device briefly. Expected; don't fight it.
3. **No multicast anything.** Requesting `com.apple.developer.networking.multicast`
   from Apple is possible but unnecessary for receive-only.
4. Bodies spill to disk past 8 MB — book files reach hundreds of MB and must
   never be fully materialized in RAM.

## File routing (iOS)

Landed files route by extension: `.epub/.pdf/.m4b/.m4a/.mp4/.mp3` → the Books
importer, `.jex` → the JEX importer (Notes). The office formats
(DOCX/ODT/PPTX/ODP/DOC) join the allowlist as their importers land.

## Porting notes (Linux / Android)

- **Linux (speechnotes-linux, Swift/GTK4)**: the endpoints map 1:1 onto a
  small SwiftNIO or GSocket HTTP listener; keep the same route table and the
  same session/token logic. Reuse `LocalSendModels` almost verbatim
  (Foundation Codable). Discovery is identical: no announcing required —
  just answer `/register` on port 53317.
- **Android**: NanoHTTPD or Ktor embedded server on 53317; Android CAN do
  multicast (`NsService`-style announce is optional), but the unicast-scan
  path already works. Register a foreground service if you want receiving
  while backgrounded — iOS's receiver dies with the app suspension, that's
  accepted behavior.
- Keep the loopback probe pattern on BOTH platforms: it is the only reliable
  liveness check everywhere, and it costs 500 ms once per foreground.
