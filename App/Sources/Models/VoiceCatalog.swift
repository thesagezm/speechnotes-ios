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
        "am_fenfir": "Fenrir",
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

    /// The Kitten pack (8 expressive voices, friendly names come from the
    /// engine itself).
    static let kitten: [VoiceDescriptor] = KittenEngine.voiceNames.map { codename in
        VoiceDescriptor(
            id: codename,
            displayName: KittenEngine.friendlyNames[codename] ?? codename,
            accent: nil,
            gender: codename.hasSuffix("-f") ? "Female" : "Male"
        )
    }

    static func descriptors(for kind: SpeechPlayer.EngineKind) -> [VoiceDescriptor] {
        kind == .kitten ? kitten : kokoro
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
