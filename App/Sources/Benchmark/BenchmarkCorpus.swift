import CryptoKit
import Foundation

/// The fixed benchmark corpus — ORIGINAL prose written for this harness, not
/// an excerpt of any published work. Content mirrors what the app actually
/// reads aloud: narration paragraphs, dialogue with quotes, contractions,
/// numbers, prices, a list. It is sanitizer-clean by construction (no
/// controls, no emoji, no markdown), which is the shape the production chunk
/// path receives after `SpeechSanitizer`/`MarkdownText`.
///
/// Determinism matters more than length: every loop re-chunks the SAME text,
/// so chunk k of loop N is directly comparable with chunk k of loop M — that
/// is what makes the RTF-vs-time curve a thermal signature rather than a
/// text artifact.
enum BenchmarkCorpus {
    static let id = "corpus-v1"

    static let text = """
    The morning train pulled out of the station at 6:42, three minutes late, \
    and the fog held the platform until the last carriage was gone. \
    "You could set a clock by it," the conductor said, "if the clock were \
    broken in exactly the same way every day."
    Mara wrote that down. She kept a notebook of things people said on the \
    6:42, and after four months it had 118 entries, 9 of which were worth \
    keeping. The fare had gone up to $5.25 in January — a 6.8% rise that the \
    announcer read as if it were weather.
    Outside, the fields ran past in long grey strips. A heron stood in the \
    ditch at Kiln Road, patient as furniture. The carriage smelled of wet \
    coats and diesel. Somewhere behind her a phone buzzed for the 4th time; \
    the owner did not pick up, and the buzzing stopped on its own.
    The tunnel came at 7:04, as it always did. For 43 seconds the windows \
    went black and the carriage spoke in a lower voice: wheels, joints, the \
    low hum of 25 kilovolts. Then daylight, and the river, flat and bright \
    as a coin, and the town with its 3 chimneys and its 1 working clock.
    She got off at the second stop, which was not her stop, and walked the \
    long way — past the bakery (open at 5:30, bread out by 6:00), past the \
    launderette with its 9 machines, 2 of which ate coins, past the house \
    where somebody had painted a door the exact green of a heron's leg.
    "Good morning," said the newsagent, not looking up.
    "Good morning," said Mara, and the day began, the way it does: all at \
    once, and 12 minutes late.
    """

    static var chars: Int { text.count }

    static var sha256Hex: String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
