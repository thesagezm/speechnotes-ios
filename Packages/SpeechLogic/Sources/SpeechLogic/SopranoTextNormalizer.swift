import Foundation

/// Rule-based text normalisation for the Soprano 1.1-80M engine.
///
/// Soprano has no phonemizer — it takes raw text through a subword
/// tokenizer, and its reference implementation normalises numbers,
/// currency, dates, ordinals and abbreviations first
/// (`soprano/utils/text_normalizer.py` upstream). Without that pass the
/// model sees "42" as digits and reads them one at a time, and "$5" as two
/// tokens.
///
/// This is that pass, reimplemented for Swift (no code copied — the rules
/// are functional). Everything here is pure so CI can test it, matching the
/// project's "logic lives in SpeechLogic" rule. `SpeechSanitizer.clean` has
/// already run upstream of this (import/speak paths), so control-character
/// handling is not repeated.
public enum SopranoTextNormalizer {

    // MARK: - Public API

    /// Normalises a sentence for Soprano. Idempotent: normalising twice
    /// yields the same string, so calling sites can be liberal.
    public static func normalize(_ text: String) -> String {
        var out = text
        // Currency first: its regex needs the digits intact ("$5"), which
        // expandNumbers would otherwise rewrite to "five".
        out = expandCurrency(out)
        // Ordinals BEFORE plain numbers: expandNumbers' digit pattern matches
        // the "1" inside "1st" and rewrites it to "one", leaving an orphan
        // "st" behind (the "onest" bug the tests caught). Expanding the
        // ordinal first consumes digit + suffix as one unit.
        out = expandOrdinals(out)
        out = expandNumbers(out)
        out = expandAbbreviations(out)
        out = tidy(out)
        return out
    }

    // MARK: - Numbers

    /// Digits → words. Handles integers, decimals, and thousands groups
    /// ("1,250" → "one thousand two hundred fifty"), zero-padded the way the
    /// reference does ("007" → "zero zero seven" — a leading-zero run is
    /// read digit by digit, which is what a listener expects from a code).
    public static func expandNumbers(_ text: String) -> String {
        // A digit run immediately followed by an ordinal suffix is an ordinal,
        // not a number — leave it for expandOrdinals (otherwise "1st" loses
        // its digits and keeps its suffix).
        let pattern = #"\d+(?:,\d{3})*(?:\.\d+)?(?!(?:st|nd|rd|th)\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let raw = ns.substring(with: match.range)
            result += numberToWords(raw)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    /// "1,250" / "42" / "3.14" / "007" → words.
    static func numberToWords(_ raw: String) -> String {
        // Leading-zero runs (codes, ids) read digit by digit.
        if raw.count > 1, raw.hasPrefix("0"), !raw.contains("."), !raw.contains(",") {
            return raw.map { String($0) }.map { ones[$0] ?? "zero" }.joined(separator: " ")
        }
        // Decimals read as "three point one four".
        if raw.contains(".") {
            let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
            let whole = parts[0].replacingOccurrences(of: ",", with: "")
            let intWords = Int(whole).flatMap { integerToWords($0) } ?? digitRun(whole)
            let fraction = parts.count > 1
                ? " point " + parts[1].map { ones[String($0)] ?? "zero" }.joined(separator: " ")
                : ""
            return intWords + fraction
        }
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard let value = Int(cleaned) else { return digitRun(raw) }
        return integerToWords(value) ?? digitRun(raw)
    }

    private static let ones: [String: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ]

    private static let teens: [String: String] = [
        "10": "ten", "11": "eleven", "12": "twelve", "13": "thirteen",
        "14": "fourteen", "15": "fifteen", "16": "sixteen", "17": "seventeen",
        "18": "eighteen", "19": "nineteen",
    ]

    private static let tens: [String: String] = [
        "2": "twenty", "3": "thirty", "4": "forty", "5": "fifty",
        "6": "sixty", "7": "seventy", "8": "eighty", "9": "ninety",
    ]

    private static func digitRun(_ raw: String) -> String {
        raw.map { ones[String($0)] ?? "zero" }.joined(separator: " ")
    }

    /// 0…999,999,999,999 → words. Returns nil outside the integer range so
    /// the caller can fall back to a digit run.
    static func integerToWords(_ value: Int) -> String? {
        guard value >= 0 else { return nil }
        if value == 0 { return "zero" }
        let scales: [(Int, String)] = [
            (1_000_000_000, "billion"),
            (1_000_000, "million"),
            (1_000, "thousand"),
        ]
        var remainder = value
        var parts: [String] = []
        for (scale, name) in scales {
            if remainder >= scale {
                let count = remainder / scale
                remainder %= scale
                if let words = underAThousand(count) {
                    parts.append("\(words) \(name)")
                }
            }
        }
        if remainder > 0, let words = underAThousand(remainder) {
            parts.append(words)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func underAThousand(_ value: Int) -> String? {
        guard value > 0, value < 1_000 else { return nil }
        var parts: [String] = []
        let hundreds = value / 100
        let rest = value % 100
        if hundreds > 0 {
            parts.append("\(ones[String(hundreds)] ?? "") hundred")
        }
        if rest > 0 {
            if rest < 10 {
                parts.append(ones[String(rest)] ?? "")
            } else if rest < 20 {
                parts.append(teens[String(rest)] ?? "")
            } else {
                let tensDigit = rest / 10
                let onesDigit = rest % 10
                let tensWord = tens[String(tensDigit)] ?? ""
                parts.append(onesDigit > 0 ? "\(tensWord) \(ones[String(onesDigit)] ?? "")" : tensWord)
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Ordinals

    /// "1st" → "first", "23rd" → "twenty third", "12th" → "twelfth".
    ///
    /// The ordinal form of the LAST word is what matters ("twenty third"),
    /// and a chained string-replacement would corrupt the earlier words
    /// ("twenty three" → "twenty third" needs the trailing word swapped, not
    /// a global replace). So: convert the number, then swap its last word
    /// through a table.
    public static func expandOrdinals(_ text: String) -> String {
        // Replace the WHOLE match (digits + suffix), not just the digits:
        // appending the words while the suffix stays behind produces
        // "onest" instead of "first" — the bug the tests caught.
        let pattern = #"(\d+)(st|nd|rd|th)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let digits = ns.substring(with: match.range(at: 1))
            if let value = Int(digits), let words = integerToWords(value) {
                result += ordinalizeLastWord(words)
            } else {
                result += ns.substring(with: match.range)
            }
            // Consume the entire match (digits AND suffix).
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    /// Cardinal-last-word → ordinal-last-word. The scale words ("hundred",
    /// "thousand") are left alone when they end the phrase — "one hundredth"
    /// is rare and a wrong expansion is worse than a missed one.
    private static func ordinalizeLastWord(_ words: String) -> String {
        var parts = words.split(separator: " ").map(String.init)
        guard let last = parts.popLast() else { return words }
        guard let ordinal = ordinalWords[last] else {
            // "fifty" → "fiftieth" (the y→ieth rule covers twenty…ninety).
            if last.hasSuffix("y") {
                parts.append(String(last.dropLast()) + "ieth")
                return parts.joined(separator: " ")
            }
            parts.append(last)
            return parts.joined(separator: " ")
        }
        parts.append(ordinal)
        return parts.joined(separator: " ")
    }

    private static let ordinalWords: [String: String] = [
        "one": "first", "two": "second", "three": "third", "four": "fourth",
        "five": "fifth", "six": "sixth", "seven": "seventh", "eight": "eighth",
        "nine": "ninth", "ten": "tenth", "eleven": "eleventh",
        "twelve": "twelfth",
    ]

    // MARK: - Currency

    /// "$5" → "five dollars", "£3.50" → "three pounds fifty", "€10" →
    /// "ten euros". Singular/plural handled; cents go after as a plain count
    /// ("fifty cents"), which is how the reference reads them.
    public static func expandCurrency(_ text: String) -> String {
        var out = text
        out = replaceCurrency(out, symbol: "$", major: "dollar", minor: "cent")
        out = replaceCurrency(out, symbol: "£", major: "pound", minor: "pence")
        out = replaceCurrency(out, symbol: "€", major: "euro", minor: "cent")
        return out
    }

    private static func replaceCurrency(
        _ text: String,
        symbol: String,
        major: String,
        minor: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        let pattern = escaped + #"(\d+(?:,\d{3})*(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let amount = ns.substring(with: match.range(at: 1))
            result += currencyWords(amount, major: major, minor: minor)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    private static func currencyWords(_ amount: String, major: String, minor: String) -> String {
        let cleaned = amount.replacingOccurrences(of: ",", with: "")
        let parts = cleaned.split(separator: ".", maxSplits: 1).map(String.init)
        let majorWords = Int(parts[0]).flatMap { integerToWords($0) } ?? digitRun(parts[0])
        let majorUnit = (parts[0] == "1") ? major : major + "s"
        guard parts.count > 1 else {
            return "\(majorWords) \(majorUnit)"
        }
        // "3.50" reads "three dollars fifty", not "three dollars fifty cents
        // zero" — the trailing zero is implied by the cents count.
        let centsText = parts[1].count >= 2 ? String(parts[1].prefix(2)) : parts[1] + "0"
        let cents = Int(centsText) ?? 0
        if cents == 0 { return "\(majorWords) \(majorUnit)" }
        let minorUnit = (cents == 1) ? minor : minor
        if let centsWords = integerToWords(cents) {
            return "\(majorWords) \(majorUnit) \(centsWords) \(minorUnit)"
        }
        return "\(majorWords) \(majorUnit) \(digitRun(centsText)) \(minorUnit)"
    }

    // MARK: - Abbreviations

    /// Common written-out forms. Deliberately short: a wrong expansion is
    /// worse than an unexpanded one, so only unambiguous everyday cases are
    /// here (the reference's list, trimmed).
    private static let abbreviations: [(pattern: String, replacement: String)] = [
        (#"(?<=\b)Mr\."#, "Mister"),
        (#"(?<=\b)Mrs\."#, "Missus"),
        (#"(?<=\b)Ms\."#, "Miss"),
        (#"(?<=\b)Dr\."#, "Doctor"),
        (#"(?<=\b)St\."#, "Saint"),
        (#"(?<=\b)e\.g\."#, "for example"),
        (#"(?<=\b)i\.e\."#, "that is"),
        (#"(?<=\b)etc\."#, "et cetera"),
        (#"(?<=\b)vs\."#, "versus"),
    ]

    public static func expandAbbreviations(_ text: String) -> String {
        var out = text
        for rule in abbreviations {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(location: 0, length: (out as NSString).length),
                withTemplate: rule.replacement
            )
        }
        return out
    }

    // MARK: - Tidying

    /// Whitespace runs collapse; sentence-final punctuation repeats collapse
    /// ("!!!" → "!"), which the reference does before tokenizing.
    public static func tidy(_ text: String) -> String {
        var out = text
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        out = out.replacingOccurrences(of: "!!!", with: "!")
        out = out.replacingOccurrences(of: "???", with: "?")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
