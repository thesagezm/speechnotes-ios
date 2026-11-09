#!/usr/bin/env python3
"""Phase 4 — convert + parity gate (runner-side, no device needed).

Three parts, run on the Apple Silicon macOS runner:

  A. KOKORO via ORT's CoreML EP vs ORT CPU on the fp32 graph — the H1
     (partition viability) + H3 (fp16-style artifacts) experiment, runner
     edition. Also captures the EP's compute-plan log.
  B. SUPERTONIC-3 via ORT's CoreML EP vs ORT CPU, same shape — the EP is
     the fallback for Supertonic if the direct conversion (C) fails.
  C. SUPERTONIC-3 direct coremltools conversion (fp16 MLProgram, static
     bucketed shapes, compute_units=ALL at predict) vs ORT CPU, end-to-end
     through the 4-model chain, then `xcrun coremlcompiler compile` of every
     .mlpackage. THIS is the shipping path's gate — C failing blocks Phase 5.

Parity thresholds reuse the repo's B4 quantization gate: length delta
<= 0.1 s or 2 %, rel-RMS < 0.25 at best ±0.5 s lag, Pearson > 0.9, zero
non-finite samples. Inputs are FIXED (seeded) and IDENTICAL for both runtimes.

Fail-soft per part: a part's failure is recorded and reported; the job exits
non-zero only if C (the shipping path) fails.

Artifacts: parity-report.json, *.mlpackage + compiled *.mlmodelc (C), the
CoreML EP compute-plan log (A/B).
"""

import json
import os
import subprocess
import sys

import numpy as np
import onnxruntime as ort

WORK = os.environ.get("PARITY_WORK", os.path.expanduser("~/parity-work"))
REPORT = {"part_a_kokoro_ep": None, "part_b_supertonic_ep": None, "part_c_supertonic_direct": None}
SEED = 20261109

KOKORO_URL = "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model.onnx"
KOKORO_TOKENIZER_URL = "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/tokenizer.json"
SUPERTONIC_BASE = "https://huggingface.co/Supertone/supertonic-3/resolve/main"
SUPERTONIC_STAGES = ["text_encoder", "duration_predictor", "vector_estimator", "vocoder"]

# §8-measured bucket edges.
KOKORO_TOKEN_BUCKET = 192
SUPERTONIC_TEXT_BUCKET = 224   # covers 59–197 observed chars
# The first 197 chars of the benchmark corpus (BenchmarkCorpus.text) — the
# §8-measured Supertonic max chunk. Same substring, byte for byte.
CORPUS_PREFIX = (
    "The morning train pulled out of the station at 6:42, three minutes late, "
    "and the fog held the platform until the last carriage was gone. "
    "\"You could set a clock by it,\" the conductor said, \"if the clock were "
    "broken in exactly the same way every day.\"\n"
    "Mara wrote that down. She kept a notebook of things people said on the "
    "6:42, and after four months it had 118 entries, 9 of which were worth "
    "keeping. The fare had gone up to $5.25 in January — a 6.8% rise that the "
    "announcer read as if it were weather."
)


def sh(cmd):
    print(f"+ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


def download(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        print(f"cached: {dest}")
        return
    print(f"downloading {url}")
    sh(f"curl -sL --retry 10 --retry-delay 2 --retry-all-errors -o '{dest}' '{url}'")


def fetch_models():
    os.makedirs(f"{WORK}/kokoro", exist_ok=True)
    os.makedirs(f"{WORK}/supertonic/onnx", exist_ok=True)
    os.makedirs(f"{WORK}/supertonic/voice_styles", exist_ok=True)
    download(KOKORO_URL, f"{WORK}/kokoro/model.onnx")
    download(KOKORO_TOKENIZER_URL, f"{WORK}/kokoro/tokenizer.json")
    for stage in SUPERTONIC_STAGES:
        download(f"{SUPERTONIC_BASE}/onnx/{stage}.onnx", f"{WORK}/supertonic/onnx/{stage}.onnx")
    download(f"{SUPERTONIC_BASE}/onnx/tts.json", f"{WORK}/supertonic/onnx/tts.json")
    download(f"{SUPERTONIC_BASE}/onnx/unicode_indexer.json", f"{WORK}/supertonic/onnx/unicode_indexer.json")
    download(f"{SUPERTONIC_BASE}/voice_styles/F1.json", f"{WORK}/supertonic/voice_styles/F1.json")


# ---------------------------------------------------------------------------
# Metrics (the B4 gate, numpy edition)

def best_lag_correlation(a, b, sample_rate=24000, max_seconds=0.5):
    """Pearson at the best ±max_seconds alignment."""
    if len(a) == 0 or len(b) == 0:
        return 0.0, 0
    a = a - a.mean()
    b = b - b.mean()
    best_r, best_lag = 0.0, 0
    max_lag_samples = int(max_seconds * sample_rate)
    step = max(1, int(0.01 * sample_rate))  # 10 ms
    for lag in range(-max_lag_samples, max_lag_samples + 1, step):
        if lag >= 0:
            x, y = a[lag:], b[: len(b) - lag]
        else:
            x, y = a[: len(a) + lag], b[-lag:]
        n = min(len(x), len(y))
        if n < int(0.2 * sample_rate):  # ignore trivial overlaps
            continue
        x, y = x[:n], y[:n]
        denom = (np.sqrt((x * x).sum()) * np.sqrt((y * y).sum()))
        if denom == 0:
            continue
        r = float((x * y).sum() / denom)
        if r > best_r:
            best_r, best_lag = r, lag
    return best_r, best_lag


def parity(wav_ref, wav_new, sample_rate=24000):
    """The B4 gate. Returns dict; `pass` is the verdict."""
    ref = np.asarray(wav_ref, dtype=np.float64).ravel()
    new = np.asarray(wav_new, dtype=np.float64).ravel()
    nonfinite = int((~np.isfinite(new)).sum())
    length_delta = abs(len(ref) - len(new))
    r, lag = best_lag_correlation(ref[: len(ref)], new[: len(new)], sample_rate=sample_rate)
    if lag >= 0:
        x, y = ref[lag:], new[: len(new) - lag]
    else:
        x, y = ref[: len(ref) + lag], new[-lag:]
    n = min(len(x), len(y))
    x, y = x[:n], y[:n]
    rel_rms = float(np.sqrt(((x - y) ** 2).mean()) / max(1e-9, np.sqrt((x * x).mean())))
    verdict = (
        nonfinite == 0
        and length_delta <= max(int(0.1 * sample_rate), int(0.02 * len(ref)))
        and rel_rms < 0.25
        and r > 0.9
    )
    return {
        "ref_samples": len(ref), "new_samples": len(new),
        "length_delta": length_delta, "best_lag": lag,
        "pearson": round(r, 4), "rel_rms": round(rel_rms, 4),
        "nonfinite": nonfinite, "pass": bool(verdict),
    }


def make_session(model_path, use_coreml_ep, log_severe=False):
    providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"] if use_coreml_ep else ["CPUExecutionProvider"]
    so = ort.SessionOptions()
    if log_severe:
        so.log_severity_level = 3
    return ort.InferenceSession(model_path, sess_options=so, providers=providers)


# ---------------------------------------------------------------------------
# Part A — Kokoro through the CoreML EP

def part_a():
    print("\n===== PART A: kokoro fp32 via ORT CoreML EP vs CPU =====")
    available = ort.get_available_providers()
    print("available providers:", available)
    if "CoreMLExecutionProvider" not in available:
        return {"pass": False, "reason": f"CoreML EP missing from wheel: {available}"}

    rng = np.random.default_rng(SEED)
    # Real-shaped tokens: valid vocab range, BOS/EOS 0s, the §8 bucket edge.
    n = KOKORO_TOKEN_BUCKET
    ids = rng.integers(1, 150, size=n - 2).astype(np.int64)
    tokens = np.concatenate([[0], ids, [0]]).reshape(1, n)
    style = (rng.standard_normal((1, 256)) * 0.05).astype(np.float32)
    speed = np.array([1.0], dtype=np.float32)

    cpu = make_session(f"{WORK}/kokoro/model.onnx", use_coreml_ep=False)
    ref = cpu.run(None, {"input_ids": tokens, "style": style, "speed": speed})[0].ravel()

    ep = make_session(f"{WORK}/kokoro/model.onnx", use_coreml_ep=True)
    new = ep.run(None, {"input_ids": tokens, "style": style, "speed": speed})[0].ravel()

    result = parity(ref, new)
    result["tokens"] = n
    print("kokoro EP parity:", json.dumps(result))
    return result


# ---------------------------------------------------------------------------
# Part B/C — the Supertonic chain

def load_supertonic_cfg():
    with open(f"{WORK}/supertonic/onnx/tts.json") as f:
        cfg = json.load(f)
    print("tts.json:", json.dumps(cfg)[:600])
    return cfg


def supertonic_inputs(cfg, bucket_text=SUPERTONIC_TEXT_BUCKET):
    """Fixed, seed-stable chain inputs. Text = the first 197 chars of the
    benchmark corpus (§8's measured Supertonic max chunk); ids through
    unicode_indexer (a 65536-entry list indexed BY CODEPOINT, -1 = unmapped →
    space id 0 — verified against the shipped tts.json/indexer pair).
    Identical arrays feed both runtimes by construction."""
    rng = np.random.default_rng(SEED + 1)
    with open(f"{WORK}/supertonic/onnx/unicode_indexer.json") as f:
        indexer = json.load(f)
    assert isinstance(indexer, list), f"indexer expected to be a codepoint list, got {type(indexer)}"
    text = CORPUS_PREFIX[:197]
    assert 59 <= len(text) <= bucket_text, f"text len {len(text)}"
    ids = []
    for ch in text:
        code = ord(ch)
        token = indexer[code] if code < len(indexer) else -1
        ids.append(int(token) if token is not None and token >= 0 else 0)
    text_len = len(ids)
    pad = bucket_text - text_len
    ids_padded = np.array(ids + [0] * pad, dtype=np.int64).reshape(1, bucket_text)
    text_mask = np.concatenate([np.ones((1, 1, text_len), np.float32),
                                np.zeros((1, 1, pad), np.float32)], axis=2)
    style_ttl = (rng.standard_normal((1, 50, 256)) * 0.05).astype(np.float32)
    style_dp = (rng.standard_normal((1, 8, 16)) * 0.05).astype(np.float32)
    return {
        "text_ids": ids_padded, "text_mask": text_mask,
        "style_ttl": style_ttl, "style_dp": style_dp,
        "text_len": text_len, "bucket_text": bucket_text,
    }


def run_chain_cpu(cfg, inp):
    """ORT CPU reference chain: encoder → duration → estimator×steps → vocoder.
    Returns (wav_ref, latent_len, duration, steps)."""
    ae = cfg.get("ae", {})
    sample_rate = int(ae.get("sample_rate", 44100))
    # One latent frame = base_chunk_size × chunk_compress_factor audio samples
    # (512 × 1 in the shipped tts.json — verified on-device config).
    hop = int(ae.get("base_chunk_size", 512)) * int(ae.get("chunk_compress_factor", 1))
    steps = 8  # the app's High dial; Helper's TextToSpeech.call totalStep

    enc = make_session(f"{WORK}/supertonic/onnx/text_encoder.onnx", False)
    dp = make_session(f"{WORK}/supertonic/onnx/duration_predictor.onnx", False)
    est = make_session(f"{WORK}/supertonic/onnx/vector_estimator.onnx", False)
    voc = make_session(f"{WORK}/supertonic/onnx/vocoder.onnx", False)

    text_emb = enc.run(None, {"text_ids": inp["text_ids"], "style_ttl": inp["style_ttl"],
                              "text_mask": inp["text_mask"]})[0]
    duration = float(dp.run(None, {"text_ids": inp["text_ids"], "style_dp": inp["style_dp"],
                                   "text_mask": inp["text_mask"]})[0].ravel()[0])
    latent_len = max(1, int(duration * sample_rate / hop) + 1)
    print(f"duration={duration:.2f}s → latent_len={latent_len} (frame {hop} samples @ {sample_rate} Hz, {steps} steps)")
    rng = np.random.default_rng(SEED + 2)
    noisy = rng.standard_normal((1, 144, latent_len)).astype(np.float32)
    latent_mask = np.ones((1, 1, latent_len), np.float32)
    total = np.array([float(steps)], np.float32)
    x = noisy
    for t in range(steps):
        cur = np.array([float(t)], np.float32)
        x = est.run(None, {"noisy_latent": x, "text_emb": text_emb, "style_ttl": inp["style_ttl"],
                           "latent_mask": latent_mask, "text_mask": inp["text_mask"],
                           "current_step": cur, "total_step": total})[0]
    wav = voc.run(None, {"latent": x})[0].ravel()
    return wav, latent_len, duration, steps


def part_b(cfg, inp, wav_ref, latent_len, steps):
    print("\n===== PART B: supertonic-3 chain via ORT CoreML EP vs CPU =====")
    available = ort.get_available_providers()
    if "CoreMLExecutionProvider" not in available:
        return {"pass": False, "reason": f"CoreML EP missing from wheel: {available}"}
    ae = cfg.get("ae", {})
    sample_rate = int(ae.get("sample_rate", 44100))
    rng = np.random.default_rng(SEED + 2)
    noisy = rng.standard_normal((1, 144, latent_len)).astype(np.float32)
    latent_mask = np.ones((1, 1, latent_len), np.float32)
    total = np.array([float(steps)], np.float32)

    def chain(provider_flag):
        enc = make_session(f"{WORK}/supertonic/onnx/text_encoder.onnx", provider_flag)
        est = make_session(f"{WORK}/supertonic/onnx/vector_estimator.onnx", provider_flag)
        voc = make_session(f"{WORK}/supertonic/onnx/vocoder.onnx", provider_flag)
        emb = enc.run(None, {"text_ids": inp["text_ids"], "style_ttl": inp["style_ttl"],
                             "text_mask": inp["text_mask"]})[0]
        x = noisy
        for t in range(steps):
            cur = np.array([float(t)], np.float32)
            x = est.run(None, {"noisy_latent": x, "text_emb": emb, "style_ttl": inp["style_ttl"],
                               "latent_mask": latent_mask, "text_mask": inp["text_mask"],
                               "current_step": cur, "total_step": total})[0]
        return voc.run(None, {"latent": x})[0].ravel()

    wav_ep = chain(True)
    result = parity(wav_ref, wav_ep, sample_rate)
    result["latent_len"] = latent_len
    print("supertonic EP parity:", json.dumps(result))
    return result


def part_c(cfg, inp, wav_ref, latent_len, steps):
    print("\n===== PART C: supertonic-3 direct coremltools conversion (fp16, static buckets) =====")
    import coremltools as ct

    ae = cfg.get("ae", {})
    sample_rate = int(ae.get("sample_rate", 44100))
    results = {"stages": {}}

    def convert(stage, inputs_desc, outputs):
        path = f"{WORK}/supertonic/onnx/{stage}.onnx"
        mlpackage = f"{WORK}/supertonic/mlpackage/{stage}.mlpackage"
        os.makedirs(os.path.dirname(mlpackage), exist_ok=True)
        print(f"converting {stage} → fp16 MLProgram …")
        model = ct.convert(
            path,
            inputs=inputs_desc,
            outputs=[ct.TensorType(name=o) for o in outputs],
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.iOS18,
        )
        model.save(mlpackage)
        sh(f"xcrun coremlcompiler compile '{mlpackage}' '{WORK}/supertonic/mlmodelc'")
        size_mb = sum(
            os.path.getsize(os.path.join(root, f)) / 1e6
            for root, _, files in os.walk(mlpackage) for f in files
        )
        print(f"  saved {mlpackage} ({size_mb:.1f} MB)")
        return ct.models.MLModel(mlpackage)

    text_len_bucket = inp["bucket_text"]
    # text_encoder
    enc_inputs = [
        ct.TensorType(name="text_ids", shape=(1, text_len_bucket), dtype=np.int64),
        ct.TensorType(name="style_ttl", shape=(1, 50, 256), dtype=np.float32),
        ct.TensorType(name="text_mask", shape=(1, 1, text_len_bucket), dtype=np.float32),
    ]
    enc_ml = convert("text_encoder", enc_inputs, ["text_emb"])
    enc_out = enc_ml.predict({
        "text_ids": inp["text_ids"],
        "style_ttl": inp["style_ttl"], "text_mask": inp["text_mask"],
    }, compute_units=ct.ComputeUnit.ALL)
    print("encoder output keys:", list(enc_out.keys()))
    text_emb_ml = enc_out["text_emb"].astype(np.float32)

    # duration_predictor (converted for the artifact set; the chain's latent
    # length comes from the CPU-side duration so both runtimes share it)
    dp_inputs = [
        ct.TensorType(name="text_ids", shape=(1, text_len_bucket), dtype=np.int64),
        ct.TensorType(name="style_dp", shape=(1, 8, 16), dtype=np.float32),
        ct.TensorType(name="text_mask", shape=(1, 1, text_len_bucket), dtype=np.float32),
    ]
    convert("duration_predictor", dp_inputs, ["duration"])

    # vector_estimator
    est_inputs = [
        ct.TensorType(name="noisy_latent", shape=(1, 144, latent_len), dtype=np.float32),
        ct.TensorType(name="text_emb", shape=(1, 256, text_len_bucket), dtype=np.float32),
        ct.TensorType(name="style_ttl", shape=(1, 50, 256), dtype=np.float32),
        ct.TensorType(name="latent_mask", shape=(1, 1, latent_len), dtype=np.float32),
        ct.TensorType(name="text_mask", shape=(1, 1, text_len_bucket), dtype=np.float32),
        ct.TensorType(name="current_step", shape=(1,), dtype=np.float32),
        ct.TensorType(name="total_step", shape=(1,), dtype=np.float32),
    ]
    est_ml = convert("vector_estimator", est_inputs, ["denoised_latent"])
    voc_inputs = [ct.TensorType(name="latent", shape=(1, 144, latent_len), dtype=np.float32)]
    voc_ml = convert("vocoder", voc_inputs, ["wav_tts"])

    rng = np.random.default_rng(SEED + 2)
    noisy = rng.standard_normal((1, 144, latent_len)).astype(np.float32)
    latent_mask = np.ones((1, 1, latent_len), np.float32)
    total = np.array([float(steps)], np.float32)
    x = noisy
    est_stages = []
    for t in range(steps):
        cur = np.array([float(t)], np.float32)
        x = est_ml.predict({
            "noisy_latent": x, "text_emb": text_emb_ml.astype(np.float16).astype(np.float32),
            "style_ttl": inp["style_ttl"], "latent_mask": latent_mask,
            "text_mask": inp["text_mask"], "current_step": cur, "total_step": total,
        }, compute_units=ct.ComputeUnit.ALL)["denoised_latent"].astype(np.float32)
        est_stages.append(float(np.abs(x).mean()))
    print("estimator stage means:", [f"{v:.4f}" for v in est_stages])
    wav_ml = voc_ml.predict({"latent": x.astype(np.float16).astype(np.float32)},
                            compute_units=ct.ComputeUnit.ALL)["wav_tts"].ravel().astype(np.float64)

    result = parity(wav_ref, wav_ml, sample_rate)
    result["latent_len"] = latent_len
    result["fp16_size_mb"] = round(sum(
        os.path.getsize(os.path.join(root, f)) / 1e6
        for root, _, files in os.walk(f"{WORK}/supertonic/mlpackage") for f in files
    ), 1)
    print("supertonic direct-conversion parity:", json.dumps(result))
    results["chain"] = result
    return results


def main():
    os.makedirs(WORK, exist_ok=True)
    print("python:", sys.version)
    print("onnxruntime:", ort.__version__)
    fetch_models()
    cfg = load_supertonic_cfg()
    inp = supertonic_inputs(cfg)
    wav_ref, latent_len, duration, steps = run_chain_cpu(cfg, inp)
    print(f"reference wav: {len(wav_ref)} samples ({len(wav_ref)/float(cfg.get('ae', {}).get('sample_rate', 44100)):.1f}s)")

    try:
        REPORT["part_a_kokoro_ep"] = part_a()
    except Exception as e:
        REPORT["part_a_kokoro_ep"] = {"pass": False, "error": repr(e)}
        print("PART A FAILED:", e)
    try:
        REPORT["part_b_supertonic_ep"] = part_b(cfg, inp, wav_ref, latent_len, steps)
    except Exception as e:
        REPORT["part_b_supertonic_ep"] = {"pass": False, "error": repr(e)}
        print("PART B FAILED:", e)
    try:
        REPORT["part_c_supertonic_direct"] = part_c(cfg, inp, wav_ref, latent_len, steps)
    except Exception as e:
        REPORT["part_c_supertonic_direct"] = {"pass": False, "error": repr(e)}
        print("PART C FAILED:", e)

    with open(f"{WORK}/parity-report.json", "w") as f:
        json.dump(REPORT, f, indent=2)
    print("\n===== SUMMARY =====")
    print(json.dumps(REPORT, indent=2))
    shipping = REPORT["part_c_supertonic_direct"]
    ok = bool(shipping and shipping.get("chain", shipping).get("pass"))
    print("SHIPPING PATH (C):", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
