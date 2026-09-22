import XCTest
import OnnxRuntimeBindings
import SpeechLogic

/// CI spike for the Soprano 1.1-80M engine (ekwek/Soprano-1.1-80M, Apache-2.0,
/// via the community ONNX export KevinAHM/soprano-1.1-onnx).
///
/// Why this gate exists (same pattern as SupertonicSpike): the app would
/// otherwise wire a whole engine — model download, ORT sessions, the
/// streaming core — against a model nobody has run through
/// onnxruntime-swift on an Apple-silicon CPU. This spike proves the contract
/// with the real int8 files first:
///
///   inputs  : input_ids / attention_mask / position_ids (int64)
///             + past_key_values[17 layers × {key,value}] (float32)
///   outputs : logits, the updated KV cache, and the final hidden states
///   decoder : hidden states [1, 512, 12] → raw float32 audio @ 32 kHz,
///             2048 samples per token
///
/// Reference implementations this loop follows:
///   • model card + config: https://huggingface.co/ekwek/Soprano-1.1-80M
///   • ONNX export:         https://huggingface.co/KevinAHM/soprano-1.1-onnx
///   • JS loop:             https://github.com/KevinAHM/soprano-web-onnx
///
/// The KV-cache plumbing is the risky part (17 layers × 2 tensors, shaped
/// [1, 1, 0, 128] on the first step and [1, 1, n, 128] after), so the spike
/// exercises a full autoregressive run of several tokens rather than a
/// single pass.
final class SopranoSpikeTests: XCTestCase {

    /// Files the CI job downloads into ~/soprano-spike/.
    private var dir: String {
        ProcessInfo.processInfo.environment["SOPRANO_DIR"] ?? NSHomeDirectory() + "/soprano-spike"
    }

    func testGenerateSpeech() throws {
        let backbone = "\(dir)/soprano_backbone_kv_int8.onnx"
        let decoder = "\(dir)/soprano_decoder_int8.onnx"
        let tokenizer = "\(dir)/tokenizer.json"
        let outPath = "\(dir)/sample.wav"

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: backbone), "backbone missing at \(backbone)")
        XCTAssertTrue(fm.fileExists(atPath: decoder), "decoder missing at \(decoder)")
        XCTAssertTrue(fm.fileExists(atPath: tokenizer), "tokenizer missing at \(tokenizer)")

        let tokenizerData = try Data(contentsOf: URL(fileURLWithPath: tokenizer))
        let tokenizerJSON = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any]
        XCTAssertNotNil(tokenizerJSON?["model"], "tokenizer.json has no model section")
        // The HF tokenizer's vocab is the app's token→id map. The export's
        // tokenizer uses a custom pre-tokenizer, but the vocab itself is a
        // plain {token: id} dictionary — enough for the spike to encode the
        // test sentence with the same lookup the app will use.
        let vocab = (tokenizerJSON?["model"] as? [String: Any])?["vocab"] as? [String: Int]
        XCTAssertNotNil(vocab, "tokenizer.json has no model.vocab")
        XCTAssertGreaterThan(vocab!.count, 1000, "vocab suspiciously small: \(vocab?.count ?? 0)")

        // Prompt format from the reference JS: "[STOP][TEXT]{batch}[START]".
        // Both markers are real tokens in this tokenizer; fall back to their
        // ids if the special-tokens map names them.
        let specials = (tokenizerJSON?["added_tokens"] as? [[String: Any]]) ?? []
        func specialID(_ name: String) -> Int? {
            specials.first { ($0["content"] as? String) == name }?["id"] as? Int
        }
        let stopID = specialID("[STOP]") ?? 3
        let startID = specialID("[START]") ?? 4
        let sentence = "This is the Soprano spike test, running fully offline."
        // Longest-match tokenization over the vocab — the app ships the real
        // pre-tokenizer; the spike only needs the encoded ids.
        var ids: [Int] = [stopID]
        ids.append(contentsOf: Self.greedyEncode(sentence, vocab: vocab!))
        ids.append(startID)
        print("SOPRANO-SPIKE encoded \(ids.count) tokens for \"\(sentence)\"")
        XCTAssertGreaterThan(ids.count, 10)

        // ---- Backbone session (Qwen3 with KV cache) ----
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        let backboneSession = try ORTSession(env: env, modelPath: backbone, sessionOptions: options)

        let backboneInputs = (try? backboneSession.inputNames()) ?? []
        let backboneOutputs = (try? backboneSession.outputNames()) ?? []
        print("SOPRANO-SPIKE backbone inputs: \(backboneInputs)")
        print("SOPRANO-SPIKE backbone outputs: \(backboneOutputs)")
        XCTAssertTrue(backboneInputs.contains("input_ids"), "missing input_ids")
        XCTAssertTrue(backboneInputs.contains("attention_mask"), "missing attention_mask")
        XCTAssertTrue(backboneInputs.contains("position_ids"), "missing position_ids")
        // 17 layers × (key, value) — the export names them past_key_values.N.key
        // / past_key_values.N.value.
        let kvKeys = backboneInputs.filter { $0.contains(".key") }
        let kvValues = backboneInputs.filter { $0.contains(".value") }
        print("SOPRANO-SPIKE KV inputs: \(kvKeys.count) keys, \(kvValues.count) values")
        XCTAssertEqual(kvKeys.count, 17, "expected 17 key inputs (config num_hidden_layers)")
        XCTAssertEqual(kvValues.count, 17, "expected 17 value inputs")

        let decoderSession = try ORTSession(env: env, modelPath: decoder, sessionOptions: options)
        let decoderInputs = (try? decoderSession.inputNames()) ?? []
        let decoderOutputs = (try? decoderSession.outputNames()) ?? []
        print("SOPRANO-SPIKE decoder inputs: \(decoderInputs) outputs: \(decoderOutputs)")

        // ---- Autoregressive loop ----
        // Total tokens to generate: the sentence is ~12 tokens, and the
        // decoder emits 2048 samples per token, so 40 tokens ≈ 2.5 s of
        // audio — comfortably above the "real speech" bar.
        let maxTokens = 40
        var pastKeys: [ORTValue] = []
        var pastValues: [ORTValue] = []
        var samples: [Float] = []
        var sequenceLen = ids.count
        var rng = SystemRandomNumberGenerator()
        var lastHidden: [Float] = []

        for step in 0..<maxTokens {
            let inputIDs: [Int64] = step == 0 ? ids.map(Int64.init) : [Int64(stopID)] // pad token while decoding
            let mask = Array(repeating: Int64(1), count: sequenceLen)
            let positionIDs = Array(stride(from: step == 0 ? 0 : sequenceLen - 1, through: sequenceLen - 1, by: 1)).map(Int64.init)

            var inputs: [String: ORTValue] = [:]
            inputs["input_ids"] = try int64Tensor(inputIDs, shape: [1, NSNumber(value: inputIDs.count)])
            inputs["attention_mask"] = try int64Tensor(mask, shape: [1, NSNumber(value: mask.count)])
            inputs["position_ids"] = try int64Tensor(positionIDs, shape: [1, NSNumber(value: positionIDs.count)])

            // Empty caches on the first step; real caches afterwards.
            if step == 0 {
                for name in backboneInputs where name.contains(".key") || name.contains(".value") {
                    inputs[name] = try floatTensor([], shape: [1, 1, 0, 128])
                }
            } else {
                for (index, name) in backboneInputs.enumerated() where name.contains(".key") {
                    inputs[name] = pastKeys[index / 2]
                }
                for (index, name) in backboneInputs.enumerated() where name.contains(".value") {
                    inputs[name] = pastValues[index / 2]
                }
            }

            let stepStart = Date()
            let outputs = try backboneSession.run(withInputs: inputs, outputNames: Set(backboneOutputs), runOptions: nil)
            let stepSeconds = Date().timeIntervalSince(stepStart)

            // Collect the refreshed caches (the export names them
            // present.N.key / present.N.value).
            pastKeys = []
            pastValues = []
            for name in backboneOutputs {
                guard let value = outputs[name] else { continue }
                if name.contains(".key") { pastKeys.append(value) }
                if name.contains(".value") { pastValues.append(value) }
            }
            XCTAssertEqual(pastKeys.count, 17, "backbone did not return 17 keys at step \(step)")
            XCTAssertEqual(pastValues.count, 17, "backbone did not return 17 values at step \(step)")

            // The export names the decoder-facing tensor
            // `last_hidden_state` (config's typical_hidden_states naming).
            // Accept either name, and fail loudly with the full output list
            // if neither is present.
            let hiddenName = backboneOutputs.contains("last_hidden_state")
                ? "last_hidden_state"
                : (backboneOutputs.contains("hidden_states") ? "hidden_states" : nil)
            guard let hiddenName, let hiddenValue = outputs[hiddenName] else {
                XCTFail("backbone has no hidden-state output — got \(backboneOutputs)")
                return
            }
            let hiddenData = try hiddenValue.tensorData() as Data
            lastHidden = hiddenData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            print("SOPRANO-SPIKE step \(step + 1)/\(maxTokens): \(lastHidden.count) hidden floats in \(String(format: "%.3f", stepSeconds))s")

            // ---- Decoder: a window of 12 hidden states -> audio ----
            let window = Array(lastHidden.suffix(2048 * 12))
            guard window.count == 2048 * 12 else {
                print("SOPRANO-SPIKE window short (\(window.count) floats) — stopping at step \(step)")
                break
            }
            let decoderOutput = try decoderSession.run(
                withInputs: ["hidden_states": try floatTensor(window, shape: [1, 512, 12])],
                outputNames: Set(decoderOutputs),
                runOptions: nil
            )
            guard let audioValue = decoderOutput.first(where: { $0.key != "hidden_states" })?.value
                    ?? decoderOutput.values.first else {
                XCTFail("decoder produced no output")
                return
            }
            let audioData = try audioValue.tensorData() as Data
            let chunk = audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            samples.append(contentsOf: chunk)

            // Temperature 0.3 / top_k 50 sampling from logits — the reference
            // loop's numbers. Softmax then draw.
            if step < maxTokens - 1 {
                let nextToken = Self.sampleNextToken(
                    logits: (outputs["logits"].map { try? $0.tensorData() as Data } ?? nil) ?? Data(),
                    temperature: 0.3,
                    topK: 50,
                    rng: &rng
                )
                // The decoded token feeds back as the next input.
                ids = [nextToken]
                sequenceLen += 1
            }
        }

        let seconds = Double(samples.count) / 32_000.0
        print("SOPRANO-SPIKE \(samples.count) samples = \(String(format: "%.2f", seconds))s audio @ 32 kHz")
        XCTAssertGreaterThan(seconds, 1.0, "output too short to be real speech")
        let peak = samples.map { abs($0) }.max() ?? 0
        print("SOPRANO-SPIKE peak amplitude \(peak)")
        XCTAssertGreaterThan(peak, 0.01, "output is silence — the graphs produced nothing")

        try WAVWriter.write(samples: samples, sampleRate: 32_000, to: URL(fileURLWithPath: outPath))
    }

    // MARK: - Helpers

    private func int64Tensor(_ values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        try ORTValue(
            tensorData: NSMutableData(bytes: values, length: values.count * MemoryLayout<Int64>.size),
            elementType: .int64,
            shape: shape
        )
    }

    private func floatTensor(_ values: [Float], shape: [NSNumber]) throws -> ORTValue {
        if values.isEmpty {
            // Zero-length tensors are valid (empty KV caches); ORT accepts a
            // non-nil empty buffer.
            return try ORTValue(
                tensorData: NSMutableData(),
                elementType: .float,
                shape: shape
            )
        }
        return try ORTValue(
            tensorData: NSMutableData(bytes: values, length: values.count * MemoryLayout<Float>.size),
            elementType: .float,
            shape: shape
        )
    }

    /// Longest-match greedy tokenization — enough for the spike to encode a
    /// sentence against the export's vocab (the app ships the real
    /// pre-tokenizer).
    static func greedyEncode(_ text: String, vocab: [String: Int]) -> [Int] {
        var ids: [Int] = []
        var i = text.startIndex
        while i < text.endIndex {
            var matched = false
            var length = text.distance(from: i, to: text.endIndex)
            while length > 0 {
                let end = text.index(i, offsetBy: length)
                if let id = vocab[String(text[i..<end])] {
                    ids.append(id)
                    i = end
                    matched = true
                    break
                }
                length -= 1
            }
            if !matched { i = text.index(after: i) }
        }
        return ids
    }

    /// Temperature + top-k sampling over the last position's logits.
    static func sampleNextToken(
        logits: Data,
        temperature: Double,
        topK: Int,
        rng: inout SystemRandomNumberGenerator
    ) -> Int {
        guard !logits.isEmpty else { return 3 }
        let values = logits.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let vocabSize = values.count
        guard vocabSize > 0 else { return 3 }
        // Top-k indices.
        let sorted = values.indices.sorted { values[$0] > values[$1] }
        let k = min(topK, vocabSize)
        let top = Array(sorted.prefix(k))
        let scaled = top.map { Double(values[$0]) / max(0.05, temperature) }
        let maxScaled = scaled.max() ?? 0
        let exps = scaled.map { Foundation.exp($0 - maxScaled) }
        let total = exps.reduce(0, +)
        guard total > 0 else { return top[0] }
        var draw = Double.random(in: 0..<1, using: &rng) * total
        for (index, weight) in exps.enumerated() {
            draw -= weight
            if draw <= 0 { return top[index] }
        }
        return top[0]
    }
}
