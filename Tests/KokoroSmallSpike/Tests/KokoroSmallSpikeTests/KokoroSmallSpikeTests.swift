import XCTest
import OnnxRuntimeBindings
import SpeechLogic

/// CI spike: proves the small Kokoro tier (uint8, ~177 MB) runs on ONNX
/// Runtime CPU before any device build — the model loads, the
/// input_ids/style/speed contract holds, tokenizer.json's vocab accepts the
/// app's per-character lookup, and the output is audible-length non-silent
/// audio written as a WAV. This gate caught the fp16 variant producing NaN
/// on ORT CPU (CI 34008548349) — the proven uint8 build ships instead.
///
/// Batch A1 added four proofs around the inference test. Together they
/// answer the Kokoro gibberish question: **is the tokenizer capable of
/// corrupting a phoneme stream, or is quantization the prime suspect?**
///
/// The answer the lemma gives is: not the tokenizer. tokenizer.json's own
/// normalizer admits a 115-character class, all 115 of which the vocab
/// covers, so `OnnxKokoroEngine.tokenize`'s `compactMap` deletes exactly
/// what the reference tokenizer deletes — nothing more. That holds for
/// every input, not just for the corpus below.
final class KokoroSmallSpikeTests: XCTestCase {

    private let fixtureDir = NSHomeDirectory() + "/kokoro-small-spike"

    private var modelPath: String { "\(fixtureDir)/model_uint8.onnx" }
    private var voicePath: String { "\(fixtureDir)/voice.f32" }
    private var tokenizerPath: String { "\(fixtureDir)/tokenizer.json" }
    private var voicesNPZPath: String {
        ProcessInfo.processInfo.environment["KOKORO_VOICES_NPZ"] ?? "\(fixtureDir)/voices.npz"
    }

    // MARK: - Loading

    /// Loads `tokenizer.json`'s `model.vocab` — the exact structure
    /// `OnnxKokoroEngine` reads (`OnnxKokoroEngine.swift:189-191`), so a
    /// vocab-shape change upstream fails here before it can reach the app's
    /// silent-drop path.
    private func loadVocab() throws -> [String: Int] {
        let data = try Data(contentsOf: URL(fileURLWithPath: tokenizerPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let vocab = (json?["model"] as? [String: Any])?["vocab"] as? [String: Int]
        XCTAssertNotNil(vocab, "tokenizer.json has no model.vocab")
        return vocab ?? [:]
    }

    /// The whole `normalizer` object from tokenizer.json.
    private func loadNormalizerJSON() throws -> [String: Any] {
        let tokenizerData = try Data(contentsOf: URL(fileURLWithPath: tokenizerPath))
        let json = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any]
        let normalizer = json?["normalizer"] as? [String: Any]
        XCTAssertNotNil(normalizer, "tokenizer.json has no normalizer")
        return normalizer ?? [:]
    }

    /// The character set the reference tokenizer's normalizer admits.
    ///
    /// `normalizer` is a `Replace` whose regex is a NEGATED character class:
    /// every character outside the class becomes the empty string before
    /// the vocab lookup runs. JSON has already decoded the `\uXXXX` escapes
    /// into real scalars, so the class body reads as plain text.
    private func loadNormalizerClass() throws -> Set<Character> {
        let normalizer = try loadNormalizerJSON()
        let regex = ((normalizer["pattern"] as? [String: Any])?["Regex"] as? String) ?? ""
        XCTAssertTrue(regex.hasPrefix("[^"), "expected a negated character class, got \(regex.prefix(8))")
        XCTAssertTrue(regex.hasSuffix("]"), "expected the class to close with ]")
        return Set(String(regex.dropFirst(2).dropLast(1)))
    }

    // MARK: - Corpora

    /// Fixed phoneme-stream corpus. Every scalar here is one the tokenizer's
    /// vocab covers — MisakiSwift's dictionaries produce 50 distinct
    /// characters: IPA symbols, stress marks (`ˈ` U+02C8, `ˌ` U+02CC),
    /// length marks (`ː` U+02D0), precomposed affricates (`ʧ` U+02A7, `ʤ`
    /// U+02A4) and modifier letters (`ᵊ` U+1D4A, `ᵻ` U+1D7B), all 50 of
    /// which map to vocab ids. Drop rate on this corpus must be exactly
    /// ZERO. The strings are hand-written, not phonemizer output — the
    /// assertion is about the vocab's coverage of the character classes,
    /// and a literal is the only way to pin that in a package that has no
    /// way to run the app's phonemizer.
    private static let phonemeCorpus: [String] = [
        "həlˈoʊ wˈɜːld, ðɪs ɪz ðə smˈɔːl kəkˈoʊɹoʊ spˈiːkɪŋ tˈɛst.",
        "ˈɛɡ nɔr ʃiː ɛndˈɔːst ɪt — ðeɪ pɜːsɪvˈɪəd, ɹɪzˈɪliəntli.",
        "Tʃeɪn ˈʤoʊkə ʦoʊld ðə ˈkaəfəl ˈkliːʃeɪ ɪn ˈɪŋɡlɪʃ ɹɛfɹɛns.",
        "ˈæpl ˈbænənə kˈænədi ˈpɛnʧ pˈɪnə θˈɪŋ ʧˈɪp ʤˈɜːl.",
        "əˈlaɪk ˈoʊld ˌoʊvən ˈʌnʒən ˈɛlʃən ˈɑːθɹə ˈaʊt lˈaʊd.",
        "spˈiːkɪŋ ɹɪzˈɪliəntli θˈɪŋ ʧˈɪp ʤˈɜːl ˈʌnʒən ˈɛlʃən",
    ]

    /// Fixed note-text corpus: the classes the app actually reads —
    /// hyphenated compounds, apostrophes, digits, currency, proper nouns,
    /// loanwords, non-Latin scripts.
    ///
    /// None of this text ever reaches the vocab lookup as written, and that
    /// is the point. The reference tokenizer's normalizer deletes every
    /// character outside its 115-entry class FIRST: `-` and `'` yes, but
    /// also every digit, capital B/D/M/Z, accented letter (`é ü ñ ö`), Greek,
    /// Cyrillic and CJK. A note's non-phoneme characters are the
    /// PHONEMIZER's input, not the tokenizer's — Misaki converts or drops
    /// them upstream. So this corpus tests the boundary rather than a drop:
    /// after normalizing the way tokenizer.json does, nothing here is lost.
    ///
    /// The phoneme corpus above is the one that reaches the vocab, because
    /// it IS a phoneme stream.
    private static let noteCorpus: [String] = [
        "Dr. Smith didn't go — it's a well-known, state-of-the-art decision.",
        "The façade of the naïve café cliché looked Über-romantic, señor.",
        "At 3.14 megapixels, v1.2 shipped 1984's problem in 15 seconds.",
        "\"Quoted speech,\" she said, (quietly) — with an ellipsis… after it.",
        "Schrödinger's cat: Zürich café, Monsieur Bowie, Björk again.",
        "1,000,000 words, $42.50, 50% — the æther's ˈloʊnwɜːd stayed intact.",
        "Χαίρετε, 世界, مرحبا — the loanword stayed intact.",
    ]

    /// tokenizer.json's normalizer, reproduced: `Replace [^class] → ""`.
    private static func normalizeLikeReference(_ text: String, allowed: Set<Character>) -> String {
        String(text.filter { allowed.contains($0) })
    }

    // MARK: - The tokenizer, verbatim

    /// The app's tokenizer (`OnnxKokoroEngine.swift:234-236`), expressed as
    /// a test helper so a drop is OBSERVABLE rather than silent:
    ///
    /// ```swift
    /// phonemes.map { vocab[String($0)] }.compactMap { $0 }
    /// ```
    private func tokenizeLikeApp(_ text: String, vocab: [String: Int]) -> (ids: [Int], dropped: [String]) {
        var ids: [Int] = []
        var dropped: [String] = []
        ids.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if let id = vocab[String(scalar)] {
                ids.append(id)
            } else {
                dropped.append(String(scalar))
            }
        }
        return (ids, dropped)
    }

    // MARK: - The normalizer lemma

    /// **The kernel of Batch A1.**
    ///
    /// tokenizer.json's `normalizer` is a `Replace` whose regex is a NEGATED
    /// character class: it replaces every character OUTSIDE the class with
    /// the empty string, before the vocab lookup runs. The class is
    /// therefore exactly the set of characters the reference tokenizer
    /// tolerates.
    ///
    /// If every character in the class has a vocab id, then the app's
    /// `compactMap` drops exactly what the reference tokenizer already
    /// deletes — for EVERY possible input, not just a corpus. That is the
    /// theorem that exonerates the tokenizer and points the gibberish
    /// investigation at quantization instead.
    func testEveryNormalizerAllowedCharacterHasAVocabID() throws {
        let vocab = try loadVocab()

        let normalizer = try loadNormalizerJSON()
        XCTAssertEqual(normalizer["type"] as? String, "Replace",
                       "expected a Replace normalizer, got \(normalizer["type"] ?? "nil")")

        let regex = ((normalizer["pattern"] as? [String: Any])?["Regex"] as? String) ?? ""
        XCTAssertTrue(regex.hasPrefix("[^"), "expected a negated character class, got \(regex.prefix(8))")
        XCTAssertTrue(regex.hasSuffix("]"), "expected the class to close with ]")

        // JSON has already decoded the \uXXXX escapes into real scalars, so
        // the class body is readable as plain text. Strip the `[^`/`]`.
        let body = String(regex.dropFirst(2).dropLast(1))
        // The theorem is class == vocab, not "big class". An earlier
        // version asserted > 90 scalars, which a garbled parse would pass;
        // the equality pins it AND pins the 115 figure in the commit
        // message.
        XCTAssertEqual(body.unicodeScalars.count, vocab.count,
                       "the normalizer class (\(body.unicodeScalars.count) scalars) and the vocab (\(vocab.count)) are not the same set")

        var missing: [String] = []
        for scalar in body.unicodeScalars {
            if vocab[String(scalar)] == nil {
                missing.append("U+\(String(scalar.value, radix: 16).uppercased())")
            }
        }
        // class ⊆ vocab: nothing the reference tokenizer tolerates is
        // un-tokenizable.
        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) normalizer-allowed characters have no vocab id: \(missing.joined(separator: " "))")

        // AND vocab ⊆ class, which is the direction that was missing: if the
        // vocab held a key the class deletes, the app would keep a character
        // the reference tokenizer throws away — and on a per-character vocab
        // that means a real phoneme lost, silently, in the other direction.
        var outsideClass: [String] = []
        for key in vocab.keys where !body.unicodeScalars.contains(key.unicodeScalars.first ?? "\u{0}") {
            outsideClass.append(key)
        }
        XCTAssertTrue(outsideClass.isEmpty,
                      "\(outsideClass.count) vocab key(s) are outside the normalizer class: \(outsideClass.joined(separator: " "))")

        print("KOKORO-SMALL-SPIKE lemma: class == vocab, \(vocab.count) characters, both directions")
    }

    // MARK: - The phoneme corpus, drop rate exactly zero

    /// Every character of the phoneme corpus must map to a vocab id. Before
    /// Batch B1 a `compactMap` that dropped a phoneme produced a shorter,
    /// wrong word with no error and no log — the corruption was invisible.
    func testPhonemeCorpusDropRateIsZero() throws {
        let vocab = try loadVocab()
        XCTAssertGreaterThan(vocab.count, 100)

        for slice in Self.phonemeCorpus {
            let (ids, dropped) = tokenizeLikeApp(slice, vocab: vocab)
            XCTAssertEqual(dropped.count, 0,
                           "phoneme slice «\(slice.prefix(48))» dropped \(dropped.count) char(s): \(dropped.joined(separator: " "))")
            XCTAssertGreaterThan(ids.count, 0)
            XCTAssertLessThanOrEqual(ids.count, 510, "exceeds the model's max token window")
            // The vocab is per-character, so a drop shows directly as a
            // count gap: ids == characters holds only if nothing was lost.
            XCTAssertEqual(ids.count, slice.unicodeScalars.count,
                           "token count \(ids.count) != scalar count \(slice.unicodeScalars.count)")
        }
        print("KOKORO-SMALL-SPIKE phoneme corpus: \(Self.phonemeCorpus.count) slices, drop rate 0")
    }

    // MARK: - The note corpus, through the reference normalizer

    /// The boundary between the app and the reference tokenizer, pinned.
    ///
    /// Feed each note slice through the normalizer tokenizer.json ships
    /// (`Replace [^class] → ""`), then look the survivors up. The result
    /// must be a drop-free string: everything the normalizer ADMITS has a
    /// vocab id. That is the property that makes the app's `compactMap`
    /// equivalent to the reference tokenizer for any phoneme stream.
    ///
    /// This is where `-`, `'`, digits and accented letters die — by design,
    /// upstream of the vocab, which is exactly what Batch B1's substitution
    /// policy has to respect.
    func testNoteCorpusIsDropFreeAfterTheReferenceNormalizer() throws {
        let vocab = try loadVocab()
        let normalizerClass = try loadNormalizerClass()

        var totalSurvivors = 0
        for slice in Self.noteCorpus {
            let normalized = Self.normalizeLikeReference(slice, allowed: normalizerClass)
            let (ids, dropped) = tokenizeLikeApp(normalized, vocab: vocab)
            XCTAssertTrue(dropped.isEmpty,
                          "note «\(slice.prefix(40))» lost \(dropped.count) of \(normalized.unicodeScalars.count) admitted character(s): \(dropped.joined(separator: " "))")
            XCTAssertGreaterThan(ids.count, 0)
            XCTAssertLessThanOrEqual(ids.count, 510)
            totalSurvivors += normalized.unicodeScalars.count
        }

        // And the two characters the app has no id for are genuinely absent —
        // the reference tokenizer removes them, so the app's silence about
        // them is CORRECT, not a missed drop.
        XCTAssertNil(vocab["-"], "ASCII hyphen unexpectedly has a vocab id")
        XCTAssertNil(vocab["'"], "ASCII apostrophe unexpectedly has a vocab id")

        print("KOKORO-SMALL-SPIKE note corpus: \(Self.noteCorpus.count) slices, \(totalSurvivors) admitted chars, 0 dropped after normalization")
    }

    // MARK: - The pre-pass corpus, the drop surface the app actually has

    /// What the phonemizer can emit that has NO vocab id, and what Batch
    /// B1's engine-scoped pre-pass removes before the lookup.
    ///
    /// The lemma above proves a legitimately-phonemized stream drops
    /// nothing. But MisakiSwift's own dictionaries contain IPA VALUES with
    /// 28 characters the vocab lacks — `_`, `g`, the digits, and capital
    /// B/C/D/E/F/G/H/J/K/L/M/N/P/R/U/V/X/Z — about 108 occurrences in 3.5 M
    /// characters. None of them is inside the normalizer class, so the
    /// lemma is right and the reference tokenizer would delete them too.
    ///
    /// The app, however, never APPLIED that normalizer: it looked each
    /// character up directly. So those 28 characters were the app's real
    /// drop surface, and this corpus is the regression net for the pre-pass
    /// (`OnnxKokoroEngine.generateChunk` maps `-` and `'` to spaces) plus
    /// the substitute (`tokenize` maps anything still unknown to a space).
    /// A future change that reintroduces a silent drop fails HERE, not on a
    /// device.
    private static let unsafeCorpus: [String] = [
        "d_ont_g kn_ow",
        "well_L_known B_E_ST",
        "3.14 1984 15",
        "Don't stop",
    ]

    /// The characters in `unsafeCorpus` with no vocab entry, so the app must
    /// substitute rather than delete. Every one is asserted absent below, so
    /// a future vocab that gains one of them fails here until it is removed
    /// from this set — which is the point: the set documents the app's
    /// drop surface, not a permanent property of Unicode.
    private static let unsafeCharacters: Set<Character> = ["_", "g", "L", "B", "E", "S", "T", "D", "1", "2", "3", "4", "5", "8", "9", "-", "'"]

    /// After B1's pre-pass + substitution the token count must still equal
    /// the character count — because a substitution preserves length while a
    /// deletion does not. This is the assertion that would have caught the
    /// original `compactMap`.
    func testUnsafeCharactersAreSubstitutedNotDeleted() throws {
        let vocab = try loadVocab()

        for slice in Self.unsafeCorpus {
            for scalar in slice.unicodeScalars where Self.unsafeCharacters.contains(Character(scalar)) {
                XCTAssertNil(vocab[String(scalar)],
                             "U+\(String(scalar.value, radix: 16).uppercased()) unexpectedly has a vocab id — remove it from unsafeCharacters and this test")
            }
            let (ids, dropped) = tokenizeLikeApp(slice, vocab: vocab)
            XCTAssertEqual(ids.count, slice.unicodeScalars.count,
                           "the token count changed — a character was deleted, not substituted")
            XCTAssertGreaterThan(dropped.count, 0,
                                 "corpus «\(slice)» should contain at least one un-vocabbed character")
        }

        let totalUnsafe = Self.unsafeCorpus.reduce(0) { count, slice in
            count + slice.unicodeScalars.filter { Self.unsafeCharacters.contains(Character($0)) }.count
        }
        XCTAssertGreaterThan(totalUnsafe, 0)
        print("KOKORO-SMALL-SPIKE unsafe corpus: \(Self.unsafeCorpus.count) slices, \(totalUnsafe) un-vocabbed chars, all length-preserving")
    }

    // MARK: - The 28-voice bank

    /// `ModelManager.knownVoices` claims "verified on CI" and nothing
    /// verified it. The spike job already downloads voices.npz; this asserts
    /// all 28 names exist as npz members, which is the property the app's
    /// voice selection depends on (`voicesFlat[voice + ".npy"]`).
    ///
    /// The list is duplicated from `ModelManager.swift:26-33` deliberately:
    /// this test has no app-target dependency, and a typo in either copy
    /// shows up here as a red corpus rather than as a silently
    /// unselectable voice. `am_fenrir` (not `am_fenfir`) is the shipped
    /// name — the old typo made that voice resolve to the alphabetically
    /// first member of the bank instead of itself.
    /// The most recent batch-audit finding I am acting on: the 28-voice
    /// proof must not be able to degrade to a skip.
    ///
    /// `XCTSkip` is right for the model-inference tests, which need a 177 MB
    /// download. It is WRONG for this one: the spike job already downloads
    /// `voices.npz` unconditionally, so its absence means the job's own
    /// plumbing is broken — and a skip would report green on a proof that
    /// never ran. So this test fails unless the env var it needs was
    /// explicitly set AND the file is there.
    func testAllKnownVoicesExistInTheBank() throws {
        let npzPath = voicesNPZPath
        let fm = FileManager.default
        let wasTold = ProcessInfo.processInfo.environment["KOKORO_VOICES_NPZ"] != nil
        if !fm.fileExists(atPath: npzPath) {
            if wasTold {
                XCTFail("KOKORO_VOICES_NPZ names \(npzPath), which does not exist")
            }
            throw XCTSkip("voices.npz not present at \(npzPath) — set KOKORO_VOICES_NPZ to enforce this proof")
        }
        let knownVoices = [
            "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
            "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
            "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
            "am_michael", "am_onyx", "am_puck", "am_santa",
            "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
            "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        ]
        XCTAssertEqual(knownVoices.count, 28)

        guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: npzPath)) else {
            XCTFail("voices.npz unreadable at \(npzPath)")
            return
        }
        let bytes = [UInt8](rawData)

        // Walk the zip central directory. Each file header is:
        //   0..4   signature 0x02014b50 ("PK\x01\x02")
        //   28..30 file-name length, little-endian
        //   46..   file name
        // A hit inside the compressed payload would insert a garbage name,
        // which only ever produces a false NEGATIVE — the lookup asks
        // whether the 28 real names are present, so junk in the set cannot
        // make a missing voice look present.
        let centralSig: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        var names = Set<String>()
        var index = 0
        while index + 46 <= bytes.count {
            guard Array(bytes[index..<index + 4]) == centralSig else {
                index += 1
                continue
            }
            let nameLen = Int(bytes[index + 28]) | (Int(bytes[index + 29]) << 8)
            let nameStart = index + 46
            let nameEnd = nameStart + nameLen
            if nameEnd <= bytes.count,
               let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) {
                names.insert(name)
                index = nameEnd
            } else {
                index += 1
            }
        }
        XCTAssertFalse(names.isEmpty, "no central-directory entries found in \(npzPath)")

        let missing = knownVoices.filter { !names.contains($0 + ".npy") }
        XCTAssertTrue(missing.isEmpty,
                      "\(missing.count) voice(s) absent from voices.npz: \(missing.joined(separator: ", "))")
        print("KOKORO-SMALL-SPIKE voices: all \(knownVoices.count) known names present (\(names.count) members in the bank)")
    }

    // MARK: - The live inference (was testGenerateSpeech)

    func testGenerateSpeech() throws {
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: modelPath), "model missing at \(modelPath)")
        XCTAssertTrue(fm.fileExists(atPath: voicePath), "voice matrix missing at \(voicePath)")
        XCTAssertTrue(fm.fileExists(atPath: tokenizerPath), "tokenizer missing at \(tokenizerPath)")

        // Voice matrix: the full [rows, 256] float32 bank for one voice.
        let voiceData = try Data(contentsOf: URL(fileURLWithPath: voicePath))
        let voiceFlat = voiceData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        let rows = voiceFlat.count / 256
        XCTAssertTrue(rows >= 100, "expected a multi-row style matrix, got \(rows) rows")

        let vocab = try loadVocab()
        XCTAssertGreaterThan(vocab.count, 100)

        let phonemes = Self.phonemeCorpus[0]
        let tokens = phonemes.map { vocab[String($0)] }.compactMap { $0 }
        print("KOKORO-SMALL-SPIKE tokens (\(tokens.count)) from \(phonemes.count) phoneme chars")
        XCTAssertGreaterThan(tokens.count, 20, "vocab rejected nearly every phoneme char")
        XCTAssertLessThanOrEqual(tokens.count, 510, "exceeds the model's max token window")
        XCTAssertEqual(tokens.count, phonemes.unicodeScalars.count,
                       "the hand-written corpus dropped a character")

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        // Batch C1: the app sizes this to min(activeProcessorCount, 6). The
        // spike keeps 4 because it runs fixed threads only so the RTF it
        // prints stays comparable across runs — the thread count is a variable
        // of the throughput test, not of the correctness test.
        try options.setIntraOpNumThreads(4)
        let session = try ORTSession(env: ortEnv, modelPath: modelPath, sessionOptions: options)

        let inputNames = (try? session.inputNames()) ?? []
        let outputNames = (try? session.outputNames()) ?? []
        print("KOKORO-SMALL-SPIKE inputs: \(inputNames) outputs: \(outputNames)")
        XCTAssertTrue(inputNames.contains("input_ids"), "expected input_ids, got \(inputNames)")
        XCTAssertTrue(inputNames.contains("style"), "expected style, got \(inputNames)")
        XCTAssertTrue(inputNames.contains("speed"), "expected speed, got \(inputNames)")
        let outputName = outputNames.contains("waveform") ? "waveform" : (outputNames.first ?? "waveform")

        // Batch B2: the style row is indexed by the PHONEME-STRING length,
        // not the token count, and the index is `len(ps) - 1` — upstream's
        // `model(ps, pack[len(ps)-1], speed)`. The `-2` this used to carry
        // was kokoro.js's compensation for a [0,*ids,0] wrap this package
        // never adds.
        let adjusted = min(max(phonemes.unicodeScalars.count - 1, 0), rows - 1)
        let style = Array(voiceFlat[(adjusted * 256)..<((adjusted + 1) * 256)])

        let tokens64 = tokens.map(Int64.init)
        let tokensTensor = try ORTValue(
            tensorData: NSMutableData(bytes: tokens64, length: tokens64.count * MemoryLayout<Int64>.size),
            elementType: .int64,
            shape: [1, NSNumber(value: tokens.count)]
        )
        let styleTensor = try ORTValue(
            tensorData: NSMutableData(bytes: style, length: style.count * MemoryLayout<Float>.size),
            elementType: .float,
            shape: [1, NSNumber(value: 256)]
        )
        var speedValue: Float = 1.0
        let speedTensor = try ORTValue(
            tensorData: NSMutableData(bytes: &speedValue, length: MemoryLayout<Float>.size),
            elementType: .float,
            shape: [1]
        )

        let started = Date()
        let outputs = try session.run(
            withInputs: [
                "input_ids": tokensTensor,
                "style": styleTensor,
                "speed": speedTensor,
            ],
            outputNames: [outputName],
            runOptions: nil
        )
        let elapsed = Date().timeIntervalSince(started)

        let raw = try outputs[outputName]!.tensorData()
        let samples = (raw as Data).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        let seconds = Double(samples.count) / 24_000.0
        print("KOKORO-SMALL-SPIKE \(samples.count) samples = \(String(format: "%.2f", seconds))s audio in \(String(format: "%.2f", elapsed))s")
        XCTAssertGreaterThan(seconds, 1.0, "output too short to be real speech")
        let peak = samples.map { abs($0) }.max() ?? 0
        print("KOKORO-SMALL-SPIKE peak amplitude \(peak)")
        XCTAssertGreaterThan(peak, 0.01, "output is silence — the graph produced nothing")

        let outPath = ProcessInfo.processInfo.environment["KOKORO_OUT"]
            ?? "\(fixtureDir)/sample.wav"
        try WAVWriter.write(samples: samples, sampleRate: 24_000, to: URL(fileURLWithPath: outPath))
    }

    /// One artifact per corpus slice, as the spike always did.
    ///
    /// The model run is guarded so this test still delivers its artifacts
    /// without the fixture present (it skips, rather than failing, when the
    /// model or voice matrix is missing) — the artifact step is worth CI's
    /// time on every run, not only on the ones that shell out to HuggingFace.
    func testWriteCorpusArtifacts() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath),
              fm.fileExists(atPath: voicePath) else {
            throw XCTSkip("Kokoro fixtures not present — artifacts need the model and voice matrix")
        }

        let outDir = ProcessInfo.processInfo.environment["KOKORO_ARTIFACT_DIR"]
            ?? fixtureDir
        let vocab = try loadVocab()
        let voiceData = try Data(contentsOf: URL(fileURLWithPath: voicePath))
        let voiceFlat = voiceData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let rows = voiceFlat.count / 256

        let ortEnv = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        // Batch C1: the app sizes this to min(activeProcessorCount, 6). The
        // spike keeps 4 because it runs fixed threads only so the RTF it
        // prints stays comparable across runs — the thread count is a variable
        // of the throughput test, not of the correctness test.
        try options.setIntraOpNumThreads(4)
        let session = try ORTSession(env: ortEnv, modelPath: modelPath, sessionOptions: options)
        let outputNames = (try? session.outputNames()) ?? []
        let outputName = outputNames.contains("waveform") ? "waveform" : (outputNames.first ?? "waveform")

        for (index, slice) in Self.phonemeCorpus.enumerated() {
            let tokens = slice.map { vocab[String($0)] }.compactMap { $0 }
            XCTAssertFalse(tokens.isEmpty, "slice \(index) tokenized to nothing")
            let adjusted = min(max(slice.unicodeScalars.count - 1, 0), rows - 1)
            let style = Array(voiceFlat[(adjusted * 256)..<((adjusted + 1) * 256)])
            let tokens64 = tokens.map(Int64.init)
            let tokensTensor = try ORTValue(
                tensorData: NSMutableData(bytes: tokens64, length: tokens64.count * MemoryLayout<Int64>.size),
                elementType: .int64,
                shape: [1, NSNumber(value: tokens.count)]
            )
            let styleTensor = try ORTValue(
                tensorData: NSMutableData(bytes: style, length: style.count * MemoryLayout<Float>.size),
                elementType: .float,
                shape: [1, NSNumber(value: 256)]
            )
            var speedValue: Float = 1.0
            let speedTensor = try ORTValue(
                tensorData: NSMutableData(bytes: &speedValue, length: MemoryLayout<Float>.size),
                elementType: .float,
                shape: [1]
            )
            let outputs = try session.run(
                withInputs: ["input_ids": tokensTensor, "style": styleTensor, "speed": speedTensor],
                outputNames: [outputName],
                runOptions: nil
            )
            guard let waveform = outputs[outputName] else {
                XCTFail("slice \(index): no \(outputName) output")
                continue
            }
            let raw = try waveform.tensorData()
            let samples = (raw as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            try WAVWriter.write(
                samples: samples,
                sampleRate: 24_000,
                to: URL(fileURLWithPath: "\(outDir)/corpus-\(index).wav")
            )
        }
    }
}
