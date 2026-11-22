"""Repeatable SenseVoice inference report using public upstream WAV fixtures."""
import argparse
import io
import json
import re
import shutil
import sys
import time
import unicodedata
import urllib.request
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server"))
import hear_cloud

REPO = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
REVISION = "2365baeacb507f821a0c8120fcee3d484dba7a07"
RATE = 16_000
WORDS = {
    "zh": "开放时间早上9点至下午5点",
    "en": "The tribal chieftain called for the boy and presented him with 50 pieces of gold",
    "ja": "うちの中学は弁当制で持っていけない場合は50円の学校販売のパンを買う",
    "ko": "조금만 생각을 하면서 살면 훨씬 편할 거야",
}


def fetch(name, destination):
    if destination.is_file():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    pending = destination.with_suffix(destination.suffix + ".download")
    try:
        with urllib.request.urlopen(f"{REPO}/resolve/{REVISION}/{name}", timeout=60) as response:
            with pending.open("wb") as output:
                shutil.copyfileobj(response, output)
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)


def read_wav(data):
    with wave.open(io.BytesIO(data), "rb") as audio:
        assert audio.getframerate() == RATE and audio.getsampwidth() == 2 and audio.getnchannels() == 1
        return np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768


def units(text, language):
    text = unicodedata.normalize("NFKC", text).casefold()
    if language == "en":
        return re.findall(r"[a-z0-9]+(?:'[a-z]+)?", text)
    return [c for c in text if c.isalnum()]


def edits(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for index, word in enumerate(reference, 1):
        row = [index]
        for j, value in enumerate(hypothesis, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (word != value)))
        previous = row
    return previous[-1]


def fixtures(root):
    originals = {}
    for language, transcript in WORDS.items():
        file = root / ("sample-" + language + ".wav")
        fetch("test_wavs/" + language + ".wav", file)
        originals[language] = read_wav(file.read_bytes())
        yield f"{language}-clean", language, transcript, originals[language]
        yield f"{language}-quiet", language, transcript, originals[language] * 0.19
    quiet = np.zeros(2 * RATE, dtype=np.float32)
    noise = np.random.default_rng(42).normal(0, 0.01, 2 * RATE).astype(np.float32)
    yield "no-speaker-silence", "", "", quiet
    yield "no-speaker-noise", "", "", noise
    count = len(originals["en"])
    room = np.random.default_rng(43).normal(0, 0.012, count).astype(np.float32)
    yield "en-noisy", "en", WORDS["en"], originals["en"] + room
    # Mixed speech is deliberately scored as a separate case.
    yield "zh-en-joined", None, WORDS["zh"] + WORDS["en"], np.concatenate((
        originals["zh"], np.zeros(RATE // 5, dtype=np.float32), originals["en"]))
    yield "short-ko", "ko", "조금만", originals["ko"][4_800:22_400]
    yield "en-long", "en", " ".join([WORDS["en"]] * 3), np.concatenate([originals["en"]] * 3)


def make_vad():
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = str(ROOT / "Hear/Resources/silero_vad.onnx")
    config.silero_vad.threshold = 0.5
    config.sample_rate = RATE
    return sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=32)


def has_voice(vad, samples):
    vad.reset()
    for offset in range(0, len(samples), 512):
        vad.accept_waveform(samples[offset:offset + 512])
        if vad.is_speech_detected():
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    model_dir = args.model_dir or args.cache / "model"
    if not args.model_dir:
        for filename in ("tokens.txt", "model.int8.onnx"):
            fetch(filename, model_dir / filename)
    hear_cloud.SENSEVOICE_DIR = str(model_dir)
    if hear_cloud.get_sensevoice() is None:
        raise RuntimeError("SenseVoice failed to initialize")
    vad = make_vad()
    results = {}
    for name, expected_lang, transcript, samples in fixtures(args.cache):
        started = time.perf_counter()
        lang, result = hear_cloud.sensevoice_transcribe(samples, RATE) if has_voice(vad, samples) else ("", "")
        milliseconds = round((time.perf_counter() - started) * 1000)
        reference = units(transcript, expected_lang)
        hypothesis = units(result, expected_lang)
        results[name] = {
            "expected_language": expected_lang,
            "language": lang,
            "missed": bool(reference) and not bool(hypothesis),
            "false_speech": not reference and bool(hypothesis),
            "wrong_language": bool(expected_lang and hypothesis and lang != expected_lang),
            "error_rate": round(edits(reference, hypothesis) / len(reference), 4) if reference else None,
            "ms": milliseconds,
            "text": result,
        }
        print(name, json.dumps(results[name], ensure_ascii=False))
    args.output.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.baseline:
        previous = json.loads(args.baseline.read_text(encoding="utf-8"))
        for name, values in results.items():
            before = previous.get(name, {})
            rate, prior = values["error_rate"], before.get("error_rate")
            if rate is not None and prior is not None and rate - prior > 0.01:
                print(f"::warning::{name} error rate increased from {prior:.1%} to {rate:.1%}")
    if any(row["false_speech"] for row in results.values()):
        raise SystemExit("Non-speech generated a transcript")
    if any(row["missed"] or row["wrong_language"] for row in results.values()):
        raise SystemExit("SenseVoice missed speech or returned the wrong language")


if __name__ == "__main__":
    main()
