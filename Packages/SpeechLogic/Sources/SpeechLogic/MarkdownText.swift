import Foundation

/// Markdown → plain text for speech and read-along display.
///
/// When "Render Markdown" is on, the engine should not hear "hashtag
/// hashtag heading" and the read-along view should not show `**bold**`.
/// This converter strips syntax while KEEPING the content and paragraph
/// structure, so `SentenceChunker` offsets map cleanly onto the same string
/// the read-along view displays.
///
/// Deliberately pragmatic (CommonMark-ish, not exhaustive): headings,
/// emphasis/strong/strikethrough markers, inline code backticks, fenced and
/// indented code blocks (content kept), links → label, images → alt text,
/// blockquote markers, list bullets (text kept), thematic breaks. Anything
/// unrecognized passes through untouched — malformed markdown just reads as
/// itself.
public enum MarkdownText {

    public static func plainText(_ markdown: String) -> String {
        var outLines: [String] = []
        var inFence = false

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks: ``` / ~~~ toggles; content kept verbatim.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence {
                    inFence = true
                } else {
                    inFence = false
                }
                outLines.append("")
                continue
            }
            if inFence {
                outLines.append(rawLine)
                continue
            }

            var line = trimmed

            // Thematic breaks (---, ***, ___ alone) vanish.
            if isThematicBreak(line) {
                outLines.append("")
                continue
            }

            // Headings: drop the leading #'s.
            if let heading = stripHeading(line) {
                line = heading
            }

            // Blockquote markers (possibly nested, possibly lazy).
            while line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            // List bullets: "- ", "* ", "+ " → keep text on its own line;
            // "3. " → keep text (the number is noise for speech).
            line = stripListMarker(line)

            // Inline transformations.
            line = stripImages(line)
            line = stripLinks(line)
            line = stripEmphasisAndCode(line)

            outLines.append(line)
        }

        // Collapse the runs of blank lines our removals can leave behind,
        // preserving single paragraph breaks.
        var paragraphs: [String] = []
        var current: [String] = []
        for line in outLines {
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: "\n"))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Block-level helpers

    private static func isThematicBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let characters = Array(line)
        let first = characters[0]
        guard first == "-" || first == "*" || first == "_" else { return false }
        var runs = 0
        for character in characters {
            if character == first {
                runs += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return runs >= 3
    }

    private static func stripHeading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        var rest = Substring(line)
        var marks = 0
        while rest.first == "#" {
            rest = rest.dropFirst()
            marks += 1
        }
        guard marks <= 6, rest.first == " " || rest.first == "\t" else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func stripListMarker(_ line: String) -> String {
        // Bullet lists.
        if let first = line.first, first == "-" || first == "*" || first == "+" {
            let rest = line.dropFirst()
            if rest.first == " " {
                return String(rest).trimmingCharacters(in: .whitespaces)
            }
        }
        // Ordered lists: digits, optional separator, space.
        if let match = line.range(of: #"^\d{1,9}[.)]\s+"#, options: .regularExpression) {
            return String(line[match.upperBound...])
        }
        return line
    }

    // MARK: - Inline helpers

    private static func stripImages(_ line: String) -> String {
        replacePatterns(line, pattern: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
    }

    private static func stripLinks(_ line: String) -> String {
        replacePatterns(line, pattern: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
    }

    /// Removes **bold**, __bold__, *italic*, _italic_, ~~strike~~ and
    /// `code` markers. Opening markers can't be followed by whitespace
    /// (CommonMark rule) which incidentally protects arithmetic like
    /// `2 * 3 * 4`; underscores also require word boundaries so snake_case
    /// identifiers survive. Nested emphasis needs repeated passes — loop
    /// until stable, bounded.
    private static func stripEmphasisAndCode(_ line: String) -> String {
        var current = line
        for _ in 0..<4 {
            let next = replacePatterns(
                replacePatterns(
                    replacePatterns(
                        replacePatterns(
                            replacePatterns(
                                current, pattern: #"`([^`]+)`"#, with: "$1"
                            ),
                            pattern: #"\*\*([^*]+)\*\*"#, with: "$1"
                        ),
                        pattern: #"__([^_]+)__"#, with: "$1"
                    ),
                    pattern: #"(?<![*\w])\*([^*\s][^*]*)\*(?!\*)"#, with: "$1"
                ),
                pattern: #"(?<![\w_])_([^_\s][^_]*)_(?![\w_])"#, with: "$1"
            )
            let strike = replacePatterns(next, pattern: #"~~([^~]+)~~"#, with: "$1")
            if strike == current { return strike }
            current = strike
        }
        return current
    }

    private static func replacePatterns(_ input: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }
}
