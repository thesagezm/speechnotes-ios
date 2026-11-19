import SwiftUI

/// The code, libraries and models this app is built on. One grouped list:
/// what each one does HERE, its license, and where it comes from.
///
/// The inventory is checked against the tree on every edit — vendored
/// pieces carry their own LICENSE/VENDOR-NOTES files (foliatejs, epubjs,
/// App/Resources/JS, the COpus and Markdown sources), the SPM dependencies
/// are pinned in project.yml / Package.resolved, and the models are the
/// URLs ModelManager actually downloads. License names were re-verified
/// against the upstream repos when this screen was built.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section("Speech engine") {
                creditRow(
                    "libopus (Xiph.Org)",
                    "The reference Opus decoder, vendored whole (Sources/COpus). Every Ogg/Opus audiobook decodes through it — the same decode flow VLC uses; Apple ships no Opus decoder at all.",
                    "BSD-3-Clause",
                    "github.com/xiph/opus"
                )
                creditRow(
                    "onnxruntime 1.24.2 (Microsoft)",
                    "The ONNX inference runtime every neural voice tier runs on. Resolved through a mirror of microsoft/onnxruntime-swift-package-manager, which Microsoft pulled from GitHub in November 2026.",
                    "MIT",
                    "github.com/microsoft/onnxruntime"
                )
                creditRow(
                    "MisakiSwift 1.0.6 (mlalma)",
                    "Swift port of the Misaki grapheme-to-phoneme engine — the English text → phoneme side of the Kokoro voice.",
                    "Apache-2.0",
                    "github.com/mlalma/MisakiSwift"
                )
                creditRow(
                    "MLX 0.30.2 (ml-explore)",
                    "Apple's MLX — the on-device ML runtime the MLX-based voice tiers run on.",
                    "MIT",
                    "github.com/ml-explore/mlx-swift"
                )
                creditRow(
                    "MLXUtilsLibrary 0.0.6 (mlalma)",
                    "iOS conveniences around MLX (model loading and inference plumbing) used by the MLX-based tiers.",
                    "Apache-2.0",
                    "github.com/mlalma/MLXUtilsLibrary"
                )
            }

            Section("Voice models (downloaded from Hugging Face)") {
                creditRow(
                    "Kokoro-82M-v1.0-ONNX + tokenizer (onnx-community)",
                    "The default voice: the Kokoro-82M TTS model as ONNX, with its tokenizer and voice bank.",
                    "Apache-2.0",
                    "huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX"
                )
                creditRow(
                    "supertonic-3 (Supertone)",
                    "Flow-matching TTS across 31 languages and 10 voices — the multilingual tier.",
                    "OpenRAIL-M (sample code MIT)",
                    "huggingface.co/Supertone/supertonic-3"
                )
                creditRow(
                    "phonon-31m-en-ONNX (onnx-community)",
                    "A 31M-parameter English streaming TTS, as ONNX.",
                    "Apache-2.0",
                    "huggingface.co/onnx-community/phonon-31m-en-ONNX"
                )
                creditRow(
                    "nano-edge-tts (drmhse)",
                    "Kokoro's text side with a 1.75M-parameter distilled decoder — the compact tier. Served from a pinned mirror of the upstream model.",
                    "Apache-2.0",
                    "huggingface.co/drmhse/nano-edge-tts"
                )
            }

            Section("Books & reading") {
                creditRow(
                    "foliate-js (John Factotum, via the readest fork)",
                    "The reader engine the epub/mobi/azw3 webview is built on — container parsing, pagination, TOC. Vendored in full with its license.",
                    "MIT",
                    "github.com/johnfactotum/foliate-js"
                )
                creditRow(
                    "epub.js 0.3.93 (futurepress) + JSZip 3.10.1",
                    "The first-generation EPUB rendering path, vendored offline (no CDN).",
                    "FreeBSD · MIT or GPLv3",
                    "github.com/futurepress/epub.js"
                )
                creditRow(
                    "KindleUnpack (kevinhendricks)",
                    "The Huff/CDIC mobi decompressor was transcribed from KindleUnpack's lib/mobi_uncompress.py — what every Kindle-produced .azw/.azw3 needs before it can be read.",
                    "GPL-3.0 (upstream; algorithm transcribed)",
                    "github.com/kevinhendricks/KindleUnpack"
                )
            }

            Section("Text & web") {
                creditRow(
                    "swift-cmark 0.7.0 (swiftlang)",
                    "CommonMark parsing for note text.",
                    "BSD-3-style",
                    "github.com/swiftlang/swift-cmark"
                )
                creditRow(
                    "swift-markdown (Apple)",
                    "The markdown AST the note formatting walks. Vendored.",
                    "Apache-2.0",
                    "github.com/swiftlang/swift-markdown"
                )
                creditRow(
                    "Readability 0.5.0 (Mozilla)",
                    "Extracts the article out of a web page before it becomes a note. Vendored offline.",
                    "Apache-2.0",
                    "github.com/mozilla/readability"
                )
            }

            Section("Slides") {
                creditRow(
                    "DeckCraft (storytold)",
                    "SlideDeckKit is a port of DeckCraft's crates — color, geom, pptx XML and the preset shapes; the geometry also ports kurbo 0.13.1, the version DeckCraft pins.",
                    "MIT / Apache-2.0",
                    "github.com/storytold/deckcraft"
                )
            }

            Section("Formats & interop") {
                creditRow(
                    "Joplin",
                    "The end-to-end encrypted notes format is an independent reimplementation of Joplin's on-disk format (no Joplin code), so a sealed note opens in either app.",
                    "format reference only",
                    "joplinapp.org"
                )
                creditRow(
                    "LocalSend",
                    "BookDrop speaks the LocalSend v2.2 protocol, implemented from its spec, so transfers interoperate with the LocalSend apps.",
                    "Apache-2.0",
                    "localsend.org"
                )
            }
        }
        .navigationTitle("Acknowledgements")
    }

    private func creditRow(_ name: String, _ detail: String, _ license: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("\(license) · \(source)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
