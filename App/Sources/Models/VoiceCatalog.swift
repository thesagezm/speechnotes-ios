import Foundation

/// Human-readable metadata for every voice the app can speak with.
///
/// Kokoro ships codenames (`af_heart`, `bm_daniel`…); users should see
/// "Heart · American female". Kitten's pack is already friendly-named but
/// gets the same descriptor treatment so the picker renders both engines
/// uniformly.
struct VoiceDescriptor: Identifiable, Hashable {
    /// The engine codename (`af_heart`, `expr-voice-5-m`) — the value stored
    /// in preferences.
    let id: String
    let displayName: String
    /// nil for packs without an accent split (Kitten).
    let accent: String?
    let gender: String

    /// "Heart · American female"
    var subtitle: String {
        [displayName, accent, gender.lowercased()]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

enum VoiceCatalog {

    /// Codenames whose spoken name isn't just a capitalized suffix.
    private static let irregularNames = [
        "am_fenrir": "Fenrir",
        "bf_lily": "Lily",
        "bm_fable": "Fable",
    ]

    /// Every Kokoro voice with friendly metadata, in `ModelManager.knownVoices`
    /// order.
    static let kokoro: [VoiceDescriptor] = ModelManager.knownVoices.map { codename in
        let suffix = codename.dropFirst(3) // "af_" / "am_" / "bf_" / "bm_"
        let name = irregularNames[codename] ?? suffix.prefix(1).uppercased() + suffix.dropFirst()
        return VoiceDescriptor(
            id: codename,
            displayName: String(name),
            accent: codename.hasPrefix("a") ? "American" : "British",
            gender: codename.contains("f_") ? "Female" : "Male"
        )
    }

    /// with no gender/accent split, and auditions use the same descriptor.
    /// The Supertonic pack — 10 voice styles (M1–M5 male, F1–F5 female),
    /// every one of them speaks all 31 languages.
    static let supertonic: [VoiceDescriptor] = ModelManager.supertonicVoices.map { id in
        VoiceDescriptor(
            id: id,
            displayName: id,
            accent: nil,
            gender: id.hasPrefix("M") ? "Male" : "Female"
        )
    }

    /// The Phonon pack — the hub default voice plus every named en-us/en-gb
    /// voice of gradium/phonon-voices (name/accent/gender from its
    /// voices.jsonl). The model ALWAYS speaks English; the accent is the
    /// accent the voice was designed in. Order = picker order: default, US,
    /// UK (females then males per accent).
    static let phonon: [VoiceDescriptor] = [
        VoiceDescriptor(id: "default", displayName: "Default", accent: nil, gender: "Neutral"),
        VoiceDescriptor(id: "NbpkqMVS3CJeq2j8", displayName: "Zoey", accent: "American", gender: "Female"),
        VoiceDescriptor(id: "NIWIOv5vTi5eRMj8", displayName: "Juniper", accent: "American", gender: "Female"),
        VoiceDescriptor(id: "vjFyp2BcCyTlUmYb", displayName: "Everly", accent: "American", gender: "Female"),
        VoiceDescriptor(id: "4SZHfMpw-p46Ywgs", displayName: "Harper", accent: "American", gender: "Female"),
        VoiceDescriptor(id: "bXwrkHhURL1VFJdG", displayName: "Hadley", accent: "American", gender: "Female"),
        VoiceDescriptor(id: "nGzMHMPAWGaJFHOo", displayName: "Delia", accent: "American", gender: "Female"),
        VoiceDescriptor(id: "LMDIYE0Oa377Qh6Z", displayName: "Easton", accent: "American", gender: "Male"),
        VoiceDescriptor(id: "40QrMVgAxFiUnP9f", displayName: "Micah", accent: "American", gender: "Male"),
        VoiceDescriptor(id: "0zLApsZfVLLNaEGl", displayName: "Trevor", accent: "American", gender: "Male"),
        VoiceDescriptor(id: "_6Aslh2DxfmnRLmP", displayName: "Russell", accent: "American", gender: "Male"),
        VoiceDescriptor(id: "qIxlZ7Ei8KvWlyQH", displayName: "Preston", accent: "American", gender: "Male"),
        VoiceDescriptor(id: "d9XCyhjo4JhkHF1d", displayName: "Miles", accent: "American", gender: "Male"),
        VoiceDescriptor(id: "6PWnV0Nq4wu7RVBT", displayName: "Maeve", accent: "British", gender: "Female"),
        VoiceDescriptor(id: "GgfEkEJtxZR7gnpy", displayName: "Freya", accent: "British", gender: "Female"),
        VoiceDescriptor(id: "uem82D50GRv2Dwma", displayName: "Pippa", accent: "British", gender: "Female"),
        VoiceDescriptor(id: "y9bQqIDnyxwqK01t", displayName: "Elodie-Rose", accent: "British", gender: "Female"),
        VoiceDescriptor(id: "gDT1nz7Ie36ZhL-C", displayName: "Imogen", accent: "British", gender: "Female"),
        VoiceDescriptor(id: "m9MxpY6IUGXtWp76", displayName: "Lottie", accent: "British", gender: "Female"),
        VoiceDescriptor(id: "gfP44RlHwr2kEwk7", displayName: "Bryony", accent: "British", gender: "Female"),
        VoiceDescriptor(id: "X6NceqF285Gr04gb", displayName: "Alfie", accent: "British", gender: "Male"),
        VoiceDescriptor(id: "YyKcxPG7iIgS3jsK", displayName: "Hugh", accent: "British", gender: "Male"),
        VoiceDescriptor(id: "zUCxzrOrugTSis03", displayName: "Edwin", accent: "British", gender: "Male"),
        VoiceDescriptor(id: "JOW0vchyswkQUMDS", displayName: "Spencer", accent: "British", gender: "Male"),
        VoiceDescriptor(id: "dME3IWyZBvmh1n1q", displayName: "Toby", accent: "British", gender: "Male"),
        VoiceDescriptor(id: "Zn7g6NxLqXlJb7Qi", displayName: "Teddy", accent: "British", gender: "Male"),
    ]

    /// Display names for Supertonic's language codes (AVAILABLE_LANGS in
    /// Helper.swift). "na" has no official expansion — labelled Neutral.
    static let supertonicLanguages: [String: String] = [
        "en": "English", "ko": "Korean", "ja": "Japanese", "ar": "Arabic",
        "bg": "Bulgarian", "cs": "Czech", "da": "Danish", "de": "German",
        "el": "Greek", "es": "Spanish", "et": "Estonian", "fi": "Finnish",
        "fr": "French", "hi": "Hindi", "hr": "Croatian", "hu": "Hungarian",
        "id": "Indonesian", "it": "Italian", "lt": "Lithuanian", "lv": "Latvian",
        "nl": "Dutch", "pl": "Polish", "pt": "Portuguese", "ro": "Romanian",
        "ru": "Russian", "sk": "Slovak", "sl": "Slovenian", "sv": "Swedish",
        "tr": "Turkish", "uk": "Ukrainian", "vi": "Vietnamese", "na": "Neutral",
    ]

    static func descriptors(for kind: SpeechPlayer.EngineKind) -> [VoiceDescriptor] {
        switch kind {
        case .supertonic: return supertonic
        case .phonon: return phonon
        default: return kokoro
        }
    }

    /// Friendly subtitle for a codename, whichever engine it belongs to.
    static func subtitle(for codename: String, kind: SpeechPlayer.EngineKind) -> String {
        descriptors(for: kind)
            .first { $0.id == codename }?
            .subtitle ?? codename
    }

    /// Short display name ("Heart") for compact chips like the mini-player.
    static func shortName(for codename: String, kind: SpeechPlayer.EngineKind) -> String {
        descriptors(for: kind)
            .first { $0.id == codename }?
            .displayName ?? codename
    }

    /// Sentence spoken when auditioning a voice in the picker — mentions the
    /// name so the user can judge how it says its own name.
    static func auditionText(for name: String) -> String {
        "Hi, I'm \(name). The quick brown fox jumps over the lazy dog — and I run fully offline, right on this phone."
    }
}

extension Note {
    /// Whitespace-separated word count of the body.
    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Rough listening-time estimate at a spoken pace of ~145 words/minute,
    /// floored at one minute for anything non-empty.
    var estimatedListenMinutes: Int? {
        guard wordCount > 0 else { return nil }
        return max(1, Int((Double(wordCount) / 145).rounded()))
    }
}
