import Foundation

/// Stable, process-independent string hashing.
///
/// `String.hashValue` is seeded per process, so a hash stored on disk would
/// mismatch on the next launch. The playback bookmark system stores this
/// digest next to the spoken text and compares it on resume to detect edits.
public enum TextHash {

    /// djb2 over Unicode scalars, masked to 63 bits (always positive).
    public static func stableHash(_ s: String) -> Int64 {
        var h: Int64 = 5381
        for scalar in s.unicodeScalars {
            h = (h &* 33 &+ Int64(scalar.value)) & 0x7FFF_FFFF_FFFF_FFFF
        }
        return h
    }
}
