#!/usr/bin/env python3
"""Phase 4 — convert + parity gate (runner-side, no device needed).

Three parts, run on the Apple Silicon macOS runner (outcomes recorded in
parity-report.json; updated 2026-11-10 after the first runner round):

  A.  KOKORO via ORT's CoreML EP vs ORT CPU on the fp32 graph — first round
      FAILED numerically (Pearson 0.63, exact length: a different utterance
      — the uint8-tier signature, i.e. the EP's internal fp16 conversion
      corrupts Kokoro's decoder path).
  A2. LOCALIZATION for A: the same model through the EP pinned to CPU+GPU,
      plus the graph split at the decoder boundary and each half parity-
      checked — tells Phase 5 whether a split can rescue ANE/GPU for
      Kokoro or whether Kokoro stays CPU.
  B.  SUPERTONIC-3 chain (encoder → estimator×8 → vocoder) via the EP vs
      CPU — first round PASSED (Pearson 1.0000, rel-RMS 0.0007). This is
      THE SHIPPING PATH for Supertonic: the EP, no conversion pipeline.
  C.  Supertonic direct coremltools conversion — DEFERRED: coremltools
      cannot ingest ONNX directly (first run failed on this), and with B
      validated the conversion is only worth building if device EP perf
      disappoints. Recorded as skipped; never fails the job.

The job's exit status follows the SHIPPING PATH (B). Inputs are FIXED
(seed) and IDENTICAL for both runtimes. Parity thresholds reuse the repo's
B4 quantization gate: length delta <= 0.1 s or 2 %, rel-RMS < 0.25 at best
±0.5 s lag, Pearson > 0.9, zero non-finite samples.
"""

import json
import os
import subprocess
import sys

import numpy as np
import onnx
import onnxruntime as ort

WORK = os.environ.get("PARITY_WORK", os.path.expanduser("~/parity-work"))
REPORT = {
    "part_a_kokoro_ep": None,
    "part_a2_kokoro_localize": None,
    "part_b_supertonic_ep": None,
    "part_c_supertonic_direct": None,
}
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


def make_session(model_path, use_coreml_ep, log_severe=False, compute_units=None):
    providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"] if use_coreml_ep else ["CPUExecutionProvider"]
    so = ort.SessionOptions()
    if log_severe:
        so.log_severity_level = 3
    # ORT requires provider_options to align with providers 1:1 — a shorter
    # list is rejected and (worse) some ORT builds then silently drop the
    # CoreML EP, which makes a parity run meaningless. The GPU/CPU pin is
    # how we separate "ANE fp16 corrupts the math" from "the partition is
    # at fault"; every session's ACTIVE providers are recorded below so a
    # silently-CPU-only run can never masquerade as an EP result again.
    provider_options = None
    if compute_units:
        provider_options = [{"MLComputeUnits": compute_units}, {}]
    sess = ort.InferenceSession(model_path, sess_options=so, providers=providers,
                                provider_options=provider_options)
    SESSION_PROVIDERS.append(sess.get_providers())
    print(f"  session active providers: {sess.get_providers()}")
    return sess


SESSION_PROVIDERS = []


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
    feeds = {"input_ids": tokens, "style": style, "speed": speed}

    cpu = make_session(f"{WORK}/kokoro/model.onnx", use_coreml_ep=False)
    ref = cpu.run(None, feeds)[0].ravel()

    ep = make_session(f"{WORK}/kokoro/model.onnx", use_coreml_ep=True)
    new = ep.run(None, feeds)[0].ravel()
    result = parity(ref, new)
    result["tokens"] = n
    result["active_providers"] = ep.get_providers()
    print("kokoro EP (ALL units) parity:", json.dumps(result))

    # A2 — localize the divergence. (1) Same model, EP pinned to CPU+GPU: if
    # parity holds WITH the CoreML EP verified active, the casualty is ANE
    # fp16; if the EP refuses nodes, the pin tells us that too. (2) Decoder-
    # subgraph extraction: compare [graph start → decoder boundary] and
    # [boundary → waveform] separately.
    localize = {"whole_all_units": dict(result)}
    gpu = make_session(f"{WORK}/kokoro/model.onnx", use_coreml_ep=True,
                       compute_units="CPUAndGPU")
    localize["gpu_pin_active_providers"] = gpu.get_providers()
    new_gpu = gpu.run(None, feeds)[0].ravel()
    localize["whole_cpu_and_gpu"] = parity(ref, new_gpu)
    print("kokoro EP (CPUAndGPU) parity:", json.dumps(localize["whole_cpu_and_gpu"]))

    try:
        stage = kokoro_stage_parity(ref_feeds=feeds)
        localize.update(stage)
    except Exception as e:
        localize["stage_extraction_error"] = repr(e)
        print("stage extraction failed:", e)

    result["localization"] = localize
    return result


def kokoro_stage_parity(ref_feeds):
    """Split the Kokoro graph at the first decoder node and parity-check each
    half through the EP. The length match in the whole-model run already
    says the duration path agrees — the suspect is the istftnet decoder."""
    model_path = f"{WORK}/kokoro/model.onnx"
    model = onnx.load(model_path, load_external_data=False)
    init_names = {init.name for init in model.graph.initializer}
    boundary = None
    for node in model.graph.node:
        if "/decoder/decoder/" in node.name:
            for inp in node.input:
                if inp and inp not in init_names:
                    boundary = inp
                    break
            if boundary:
                break
    print(f"decoder boundary tensor: {boundary}")
    if not boundary:
        return {"boundary_found": False}

    pre_path = f"{WORK}/kokoro/stage_pre.onnx"
    dec_path = f"{WORK}/kokoro/stage_decoder.onnx"
    onnx.utils.extract_model(model_path, pre_path, list(ref_feeds.keys()), [boundary])
    onnx.utils.extract_model(model_path, dec_path, [boundary], ["waveform"])

    out = {"boundary_found": True, "boundary_tensor": boundary}
    pre_cpu_out = make_session(pre_path, False).run(None, list(ref_feeds.values()))[0]
    pre_ep_out = make_session(pre_path, True).run(None, list(ref_feeds.values()))[0]
    out["stage_pre_decoder"] = parity(np.asarray(pre_cpu_out).ravel(), np.asarray(pre_ep_out).ravel())

    # Decoder isolation: BOTH decoders consume the CPU pre-stage output, so
    # this measures the decoder under the EP alone, not accumulated drift.
    dec_cpu_session = make_session(dec_path, False)
    dec_ep_session = make_session(dec_path, True)
    dec_ref = dec_cpu_session.run(None, {boundary: pre_cpu_out})[0].ravel()
    dec_new = dec_ep_session.run(None, {boundary: pre_cpu_out})[0].ravel()
    out["stage_decoder"] = parity(dec_ref, dec_new)
    print("kokoro stage localization:", json.dumps(out))
    return out


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
    # Prove the CoreML EP actually carried nodes for the chain's sessions
    # (a silently-CPU-only fallback would make this parity trivial).
    result["active_providers"] = SESSION_PROVIDERS[-4:] if len(SESSION_PROVIDERS) >= 4 else SESSION_PROVIDERS[:]
    print("supertonic EP parity:", json.dumps(result))
    return result


def part_c(cfg, inp, wav_ref, latent_len, steps):
    """DEFERRED (2026-11-10 runner round): coremltools cannot ingest ONNX
    directly (source must be pytorch/tensorflow — the first run failed on
    exactly this). The route to a direct conversion is onnx2torch + trace,
    which adds a torch dependency and conversion risk for a path that is
    currently UNNEEDED: Part B proved the ORT CoreML EP is numerically
    perfect for the whole Supertonic-3 chain, so the shipping path is the
    EP and this experiment only matters if device EP perf disappoints.
    Recorded as skipped, not failed."""
    print("\n===== PART C: supertonic-3 direct conversion — DEFERRED =====")
    return {
        "skipped": True,
        "reason": ("coremltools cannot ingest ONNX directly (source must be "
                   "pytorch/tensorflow); onnx2torch route deferred — Part B "
                   "validated the EP as the shipping path. Revisit only if "
                   "device EP performance disappoints."),
    }


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
    # The shipping gate is Part B: Supertonic rides the ORT CoreML EP (Part B
    # validated its numerics); Kokoro stays CPU unless its localization (A2)
    # yields a viable split. Part C is a deferred experiment, never a failure.
    shipping = REPORT["part_b_supertonic_ep"]
    ok = bool(shipping and shipping.get("pass"))
    print("SHIPPING PATH (B — Supertonic via CoreML EP):", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
