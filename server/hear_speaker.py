"""Extract a single speaker embedding from a finalized utterance."""
import math
from pathlib import Path
import threading


class SpeakerDetector:
    def __init__(self, model_path):
        self.path = Path(model_path)
        self.extractor = None
        self.slot = threading.Lock()

    @property
    def available(self):
        try:
            return self.path.stat().st_size > 1_000_000
        except OSError:
            return False

    def embedding(self, samples, rate):
        if not self.available or not 8000 <= rate <= 48000 or len(samples) < rate * 1.4:
            return None
        if not self.slot.acquire(blocking=False):
            return None
        try:
            if self.extractor is None:
                import sherpa_onnx
                config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                    model=str(self.path), num_threads=1, provider="cpu", debug=False)
                if not config.validate():
                    return None
                self.extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
            stream = self.extractor.create_stream()
            stream.accept_waveform(sample_rate=rate, waveform=samples[:rate * 10])
            stream.input_finished()
            if not self.extractor.is_ready(stream):
                return None
            result = [float(x) for x in self.extractor.compute(stream)]
            return result if 0 < len(result) <= 512 and all(math.isfinite(x) for x in result) else None
        finally:
            self.slot.release()
