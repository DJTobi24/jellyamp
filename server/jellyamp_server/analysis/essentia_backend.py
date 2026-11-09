"""Essentia/MusiCNN analysis backend (optional `analysis` extra, AGPL-3.0).

Learned 200-dimensional MusiCNN embeddings: better musical similarity than
the DSP backend, at the cost of TensorFlow, an x86-64-only wheel and a model
file (`MUSICNN_MODEL_PATH`, see server/README.md).
"""

import tempfile
from pathlib import Path

import numpy as np

from jellyamp_server.analysis import audio
from jellyamp_server.analysis.base import AnalysisError, AnalysisResult

try:  # pragma: no cover - exercised only in the analysis image
    import essentia.standard as es

    ESSENTIA_AVAILABLE = True
except ImportError:  # pragma: no cover
    es = None
    ESSENTIA_AVAILABLE = False

EMBEDDING_DIM = 200


def unavailable_reason(model_path: str) -> str | None:
    """None when the backend can run; otherwise why not (for logs/errors)."""
    if not ESSENTIA_AVAILABLE:
        return "essentia-tensorflow is not installed (pip install '.[analysis]')"
    if not Path(model_path).is_file():
        return f"MusiCNN model file not found at {model_path!r} (set MUSICNN_MODEL_PATH)"
    return None


class EssentiaExtractor:  # pragma: no cover - needs essentia + model file
    name = "musicnn"
    version = "msd-1"
    dim = EMBEDDING_DIM
    standardize = False
    weights: np.ndarray | None = None

    def __init__(self, model_path: str, ffmpeg: str = "ffmpeg"):
        reason = unavailable_reason(model_path)
        if reason:
            raise RuntimeError(reason)
        self._ffmpeg = ffmpeg
        # Loading the TensorFlow graph is slow; do it once, not per track.
        self._model = es.TensorflowPredictMusiCNN(
            graphFilename=model_path, output="model/dense/BiasAdd"
        )

    def analyze(self, audio_bytes: bytes) -> AnalysisResult:
        with tempfile.NamedTemporaryFile(suffix=".audio") as tmp:
            tmp.write(audio_bytes)
            tmp.flush()
            try:
                audio_16k = es.MonoLoader(filename=tmp.name, sampleRate=16000)()
            except RuntimeError as error:
                raise AnalysisError(f"essentia could not decode clip: {error}") from error
        if len(audio_16k) < 3 * 16000:
            raise AnalysisError("clip too short for analysis")
        # Mean-pool patch embeddings into one vector per track.
        patches = self._model(audio_16k)
        embedding = np.mean(patches, axis=0).astype(np.float32)

        # Loudness comes from the same ffmpeg measurement as the DSP backend
        # so values do not shift when a user switches backends.
        integrated_lufs: float | None = None
        true_peak: float | None = None
        if audio.ffmpeg_available(self._ffmpeg):
            decoded = audio.decode(audio_bytes, ffmpeg=self._ffmpeg, sample_rate=16000)
            integrated_lufs, true_peak = decoded.integrated_lufs, decoded.true_peak
        return AnalysisResult(embedding, integrated_lufs, true_peak)
