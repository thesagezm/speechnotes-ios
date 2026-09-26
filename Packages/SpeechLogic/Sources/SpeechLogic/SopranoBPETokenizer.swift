import Foundation

/// Soprano's REAL tokenizer, rebuilt from the export's tokenizer.json
/// (BPE, 135 merges): lowercase + whitespace collapse, pre-tokenize with
/// `\s+|\w+|[^\w\s]+`, split digits individually, then rank-ordered BPE
/// merges per pre-token.
///
/// Why this replaced greedy longest-match: the engine was feeding the model
/// token sequences BPE would never produce (greedy can match substrings the
/// merges never build). The fixtures in SopranoBPETokenizerTests were
/// generated with the reference algorithm over the actual vocab/merges, so
/// CI pins the Swift port to the reference byte-for-byte on those inputs.
public struct SopranoBPETokenizer {
    public let vocab: [String: Int]
    /// Pair → merge rank. Keys join the pair with U+0001; pre-tokens that
    /// reach BPE never contain that control byte (whitespace is split out).
    private let ranks: [String: Int]
    private let unkID: Int

    public init?(vocab: [String: Int], merges: [[String]]) {
        guard !vocab.isEmpty else { return nil }
        var ranks: [String: Int] = [:]
        for (index, merge) in merges.enumerated() where merge.count == 2 {
            ranks[merge[0] + "\u{1}" + merge[1]] = index
        }
        self.vocab = vocab
        self.ranks = ranks
        self.unkID = vocab["[UNK]"] ?? 0
    }

    /// Builds from a parsed tokenizer.json — accepts both merge encodings
    /// HF writes: ["a","b"] pairs and legacy "a b" strings.
    public static func make(from tokenizerJSON: [String: Any]) -> SopranoBPETokenizer? {
        guard let model = tokenizerJSON["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: Int] else { return nil }
        var merges: [[String]] = []
        if let raw = model["merges"] as? [[String]] {
            merges = raw
        } else if let raw = model["merges"] as? [String] {
            merges = raw.map { $0.components(separatedBy: " ") }
        }
        return SopranoBPETokenizer(vocab: vocab, merges: merges)
    }

    // MARK: - Encoding

    public func encode(_ text: String) -> [Int] {
        // The tokenizer.json normalizer: lowercase, collapse whitespace.
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
        var ids: [Int] = []
        ids.reserveCapacity(collapsed.utf16.count / 3 + 4)
        for preToken in Self.preTokens(in: collapsed) {
            if preToken.allSatisfy({ $0 == " " }) {
                // Whitespace pieces pass straight through (Isolated behavior).
                ids.append(vocab[preToken] ?? unkID)
                continue
            }
            for piece in Self.splitDigits(in: preToken) {
                for symbol in bpe(piece) {
                    ids.append(vocab[symbol] ?? unkID)
                }
            }
        }
        return ids
    }

    /// Rank-ordered BPE over one pre-token's characters.
    private func bpe(_ word: String) -> [String] {
        var symbols = word.map { String($0) }
        guard symbols.count > 1 else { return symbols }
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(symbols.count - 1) {
                if let rank = ranks[symbols[i] + "\u{1}" + symbols[i + 1]], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }
            symbols[bestIndex..<(bestIndex + 2)] = [symbols[bestIndex] + symbols[bestIndex + 1]]
        }
        return symbols
    }

    /// The export's pre_tokenizer: Digits(individual_digits) then Split on
    /// `\s+|\w+|[^\w\s]+` — the Split keeps every piece, so a plain regex
    /// match-walk reproduces it. Digit runs then split per character.
    static func preTokens(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\s+|\w+|[^\w\s]+"#) else {
            return [text]
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }

    /// Digits(individual_digits: true) — every digit stands alone, the rest
    /// of the run stays together.
    static func splitDigits(in preToken: String) -> [String] {
        guard preToken.contains(where: \.isNumber) else { return [preToken] }
        var pieces: [String] = []
        var buffer = ""
        for ch in preToken {
            if ch.isNumber {
                if !buffer.isEmpty { pieces.append(buffer); buffer = "" }
                pieces.append(String(ch))
            } else {
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty { pieces.append(buffer) }
        return pieces
    }
}
