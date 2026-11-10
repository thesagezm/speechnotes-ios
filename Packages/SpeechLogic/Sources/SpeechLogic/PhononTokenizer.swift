import Foundation

/// Phonon's Unigram tokenizer — the `onnx-community/phonon-31m-en-ONNX`
/// tokenizer.json contract, ported for the PhononEngine (App/Sources/Engine).
///
/// Pipeline, mirroring the hub tokenizer exactly:
///   1. the 191-step normalizer chain (PhononNormalizerTable, generated data:
///      quote/dash folding, accented-letter folding to ASCII, subscript →
///      digit, symbol/emoji runs → space, whitespace collapse, terminal
///      period, leading "▁");
///   2. the Metaspace pre-tokenizer: remaining spaces become "▁", and the
///      text splits into segments at every "▁" (a piece never spans a space);
///   3. per segment, a Unigram Viterbi over the vocab's 4000 pieces; bytes
///      no piece covers fall back to the vocab's 256 <0xXX> byte tokens.
///
/// The audio specials (<|audio_bos|> 4, <|audio_prompt|> 5,
/// <|audio_latent|> 6) are excluded from matching on purpose: a note that
/// literally contained "<|audio_bos|>" must never inject that control token
/// into the flow model's stream — it falls back to bytes like any other
/// unknown text. The NUL-prefixed pieces (<unk>, <s>, <|c###|>) cannot match
/// normalized text at all and are dropped at load.
///
/// Verified against the reference `tokenizers` implementation: the fixtures
/// in PhononTokenizerTests pin identical ids for plain prose, punctuation,
/// accented text, digits and off-alphabet symbols/emoji.
public struct PhononTokenizer {
    private struct Piece {
        let id: Int
        let score: Double
    }

    private enum CompiledStep {
        case replace(NSRegularExpression, String)
        case strip
        case prepend(String)
    }

    /// The audio control tokens, by their fixed ids in this vocab.
    public static let audioBosTokenID = 4
    public static let audioPromptTokenID = 5
    public static let audioLatentTokenID = 6

    private static let metaspace: Character = "\u{2581}"
    private static let audioSpecialPieces: Set<String> = ["<|audio_bos|>", "<|audio_prompt|>", "<|audio_latent|>"]
    /// Longest possible piece in bytes (16 chars × 4 UTF-8 bytes worst case).
    private static let maxPieceBytes = 64

    private var vocab: [String: Piece] = [:]
    private var byteTokens: [UInt8: Int] = [:]
    private var steps: [CompiledStep] = []

    public enum TokenizerError: LocalizedError {
        case malformedTokenizerJSON
        case noByteFallback
        case unencodable(String)

        public var errorDescription: String? {
            switch self {
            case .malformedTokenizerJSON: return "Phonon's tokenizer.json is not a Unigram vocab the engine can read."
            case .noByteFallback: return "Phonon's tokenizer.json lacks byte fallback — it cannot encode off-alphabet text."
            case .unencodable: return "Phonon's tokenizer could not encode a sentence."
            }
        }
    }

    /// - Parameter tokenizerData: the hub's tokenizer.json bytes (downloaded
    ///   with the model set; the test fixture carries the same file).
    public init(tokenizerData: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any],
              let model = json["model"] as? [String: Any],
              model["type"] as? String == "Unigram",
              let rawVocab = model["vocab"] as? [[Any]]
        else { throw TokenizerError.malformedTokenizerJSON }
        guard (model["byte_fallback"] as? Bool) == true else { throw TokenizerError.noByteFallback }

        // The id of a piece IS its index in the raw vocab list.
        for (index, entry) in rawVocab.enumerated() {
            guard entry.count >= 2,
                  let piece = entry[0] as? String,
                  let score = entry[1] as? NSNumber else { continue }
            // Byte-fallback tokens (<0x00>…<0xFF>) resolve by name here; the
            // \x00-prefixed control pieces (<unk>, <s>, <|c###|>) are
            // unmatchable by construction and skipped.
            if piece.contains("\u{0000}") { continue }
            if piece.hasPrefix("<0x"), piece.hasSuffix(">"), piece.count == 6,
               let byte = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                byteTokens[byte] = index
                continue
            }
            // The audio control tokens must never be produced from user text
            // (see the type doc); treat them as absent.
            if Self.audioSpecialPieces.contains(piece) { continue }
            vocab[piece] = Piece(id: index, score: score.doubleValue)
        }
        guard vocab.count > 3000, byteTokens.count == 256 else { throw TokenizerError.malformedTokenizerJSON }

        for step in PhononNormalizerTable.steps {
            switch step {
            case .replace(let pattern, let replacement):
                steps.append(.replace(try NSRegularExpression(pattern: pattern, options: []), replacement))
            case .strip:
                steps.append(.strip)
            case .prepend(let text):
                steps.append(.prepend(text))
            }
        }
    }

    private func applyNormalizer(_ text: String) -> String {
        var result = text
        for step in steps {
            switch step {
            case .replace(let regex, let replacement):
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            case .strip:
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            case .prepend(let prefix):
                // HF's Prepend skips empty strings — this is what keeps
                // stripped-bare text from becoming a lone "▁" piece.
                if !result.isEmpty { result = prefix + result }
            }
        }
        return result
    }

    /// Text → token ids, the exact input contract of the flow graph's
    /// `input_ids` (add_special_tokens is implicit: this vocab adds none).
    public func encode(_ text: String) throws -> [Int] {
        var normalized = applyNormalizer(text)
        // HF's Prepend/Metaspace skip empty strings — text the normalizer
        // strips bare ("   ") encodes to NOTHING, not to a lone "▁" piece
        // (verified against the reference tokenizer).
        guard !normalized.isEmpty else { return [] }
        // Metaspace pre-tokenizer: spaces → "▁" (the normalizer's final
        // Prepend already put the leading one), then split at every "▁".
        normalized = String(normalized.map { $0 == " " ? Self.metaspace : $0 })

        var ids: [Int] = []
        var segment = ""
        func flush() throws {
            guard !segment.isEmpty else { return }
            ids.append(contentsOf: try encodeSegment(segment))
            segment = ""
        }
        for char in normalized {
            if char == Self.metaspace {
                try flush()
                segment = String(Self.metaspace)
            } else {
                segment.append(char)
            }
        }
        try flush()
        return ids
    }

    /// Unigram Viterbi over one "▁"-anchored segment: a byte lattice where
    /// every byte position gets the vocab pieces matching there, and byte
    /// tokens only when no piece matches starting at that byte (HF Unigram's
    /// lattice rule).
    private func encodeSegment(_ segment: String) throws -> [Int] {
        let bytes = Array(segment.utf8)
        let count = bytes.count
        guard count > 0 else { return [] }

        var best = [Double?](repeating: nil, count: count + 1)
        var back = [(id: Int, prev: Int)](repeating: (0, 0), count: count + 1)
        best[0] = 0

        var pieceBuffer = [UInt8]()
        pieceBuffer.reserveCapacity(Self.maxPieceBytes)

        for i in 0..<count {
            // HF's lattice keeps nodes at every byte position (byte tokens
            // wherever no piece matches), so a position can sit unreachable
            // behind a longer piece's span — skip it; reachability always
            // advances past it via that span.
            guard let current = best[i] else { continue }
            let upper = min(i + Self.maxPieceBytes, count)
            var matched = false
            for j in (i + 1)...upper {
                pieceBuffer.removeAll(keepingCapacity: true)
                pieceBuffer.append(contentsOf: bytes[i..<j])
                guard let piece = String(bytes: pieceBuffer, encoding: String.Encoding.utf8) else { continue }
                if let entry = vocab[piece] {
                    matched = true
                    let candidate = current + entry.score
                    if best[j] == nil || candidate > best[j]! {
                        best[j] = candidate
                        back[j] = (entry.id, i)
                    }
                }
            }
            if !matched {
                guard let byteID = byteTokens[bytes[i]] else {
                    throw TokenizerError.unencodable(segment)
                }
                // Byte tokens carry score 0 in this vocab.
                if best[i + 1] == nil || current > best[i + 1]! {
                    best[i + 1] = current
                    back[i + 1] = (byteID, i)
                }
            }
        }
        guard best[count] != nil else { throw TokenizerError.unencodable(segment) }

        var ids: [Int] = []
        var cursor = count
        while cursor > 0 {
            let step = back[cursor]
            ids.append(step.id)
            cursor = step.prev
        }
        return ids.reversed()
    }
}
