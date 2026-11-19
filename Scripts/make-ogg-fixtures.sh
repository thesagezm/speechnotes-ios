#!/usr/bin/env bash
# Ogg/Opus fixtures for OggReaderTests.
#
# Generated rather than committed: they are binary, they are small, and every
# one of them is the output of a real muxer — which is the point. OggReader's
# page/segment walk is only correct if it is tested against the layouts
# ffmpeg and libopus actually emit, and hand-written bytes would test the
# test author's idea of Ogg instead of Ogg.
#
# Usage: Scripts/make-ogg-fixtures.sh <output-dir>
# Requires: ffmpeg with libopus and libvorbis (any distro package will do).

set -euo pipefail

OUT="${1:-$(dirname "$0")/../Tests/SpeechLogicTests/Fixtures/Ogg}"
mkdir -p "$OUT"

# `grep -q` exits as soon as it matches, which SIGPIPEs ffmpeg's stdout — and
# under `set -o pipefail` that makes the whole probe look like a failure on
# every machine. Capture the list once instead.
ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
have() { [[ "$ENCODERS" == *"$1"* ]]; }
have libopus   || { echo "ffmpeg has no libopus encoder" >&2; exit 1; }
have libvorbis || { echo "ffmpeg has no libvorbis encoder" >&2; exit 1; }

gen() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# 3 s mono 440 Hz, 32 kbps — the "a store book with no M4B" shape. ~15 KB.
gen -f lavfi -i "sine=frequency=440:duration=3" \
    -c:a libopus -b:a 32k "$OUT/plain.opus"

# The same audio with Vorbis tags, so the OpusTags header packet exists and
# the test can assert header ordering.
gen -f lavfi -i "sine=frequency=440:duration=3" \
    -c:a libopus -b:a 32k \
    -metadata title="Ogg Reader Fixture" -metadata artist="Speechnotes" \
    "$OUT/tagged.opus"

# 2 minutes — long enough for packets to span several pages, and the file the
# seek and chapter-boundary tests run against.
gen -f lavfi -i "sine=frequency=440:duration=120" \
    -c:a libopus -b:a 32k "$OUT/long.opus"

# Opus inside an .ogg extension: the two must behave identically, because
# callers route on the CONTAINER and the extension is only a hint.
gen -f lavfi -i "sine=frequency=330:duration=5" \
    -c:a libopus -b:a 48k "$OUT/opusinaogg.ogg"

# Valid Ogg, NOT Opus. The reader must refuse to call this Opus rather than
# hand Vorbis packets to the Opus decoder.
gen -f lavfi -i "sine=frequency=220:duration=2" \
    -c:a libvorbis -b:a 64k "$OUT/realvorbis.oga"

# The same 3 s sine with an embedded COVER, the shape every store-bought
# Opus encode carries. ffmpeg 7.1+ can mux a real attached_pic; the 6.x
# on this box cannot (`Unsupported codec id in stream 1`), so the picture
# goes through the muxer's metadata passthrough instead — it lands as the
# SAME METADATA_BLOCK_PICTURE Vorbis comment an attached_pic would write,
# which is what OggReader.artwork parses. The constant is the FLAC picture
# block, big-endian throughout: type 3 (front cover) | mime "image/png" |
# description "Cover" | width/height/depth/colours = 0 (unknown) | the
# bytes of a stock 1×1 steelblue PNG.
gen -f lavfi -i "sine=frequency=440:duration=3" \
    -c:a libopus -b:a 32k \
    -metadata title="Cover Fixture" -metadata artist="Speechnotes" \
    -metadata METADATA_BLOCK_PICTURE="AAAAAwAAAAlpbWFnZS9wbmcAAAAFQ292ZXIAAAAAAAAAAAAAAAAAAAAAAAAARolQTkcNChoKAAAADUlIRFIAAAABAAAAAQgGAAAAHxXEiQAAAA1JREFUeNpj/M/AUA8ABIUBgISpjCEAAAAASUVORK5CYII=" "$OUT/cover.opus"

# A file whose bytes are NOT Ogg at all, with an Ogg-ish name — the shape a
# mis-muxed or truncated download takes. Hand-written on purpose: no encoder
# will produce it.
printf 'this is not an ogg stream, it is 4 KB of the letter A\n%.0s' \
    {1..70} > "$OUT/notogg.oga"

echo "Wrote fixtures to $OUT:"
for f in "$OUT"/*; do
    printf '  %-20s %8s bytes  %s\n' \
        "$(basename "$f")" \
        "$(stat -c%s "$f")" \
        "$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null || echo '—')"
done