"""Per-track analysis: audio embedding + EBU R128 loudness.

Essentia (with the MusiCNN model) is an optional heavy dependency; when it is
not installed the extractor reports unavailable and the API drops the
corresponding capabilities. This keeps tests and slim deployments light and
makes the extractor pluggable (ADR-0004).
"""

from dataclasses import dataclass

import numpy as np

try:  # pragma: no cover - exercised only in the analysis image
    import essentia.standard as es

    ESSENTIA_AVAILABLE = True
except ImportError:  # pragma: no cover
    ESSENTIA_AVAILABLE = False

EMBEDDING_DIM = 200
MUSICNN_MODEL_PATH = "jellyamp_server/analysis/models/msd-musicnn-1.pb"


@dataclass
class AnalysisResult:
    embedding: np.ndarray
    integrated_lufs: float
    true_peak: float


def is_available() -> bool:
    return ESSENTIA_AVAILABLE


def analyze_clip(audio_bytes: bytes) -> AnalysisResult:  # pragma: no cover
    """Decode an MP3 clip and compute embedding + loudness via Essentia."""
    if not ESSENTIA_AVAILABLE:
        raise RuntimeError("essentia-tensorflow is not installed (install the 'analysis' extra)")

    import tempfile

    with tempfile.NamedTemporaryFile(suffix=".mp3") as tmp:
        tmp.write(audio_bytes)
        tmp.flush()
        audio_16k = es.MonoLoader(filename=tmp.name, sampleRate=16000)()
        audio_44k = es.MonoLoader(filename=tmp.name, sampleRate=44100)()

    embedding_model = es.TensorflowPredictMusiCNN(
        graphFilename=MUSICNN_MODEL_PATH,
        output="model/dense/BiasAdd",
    )
    # Mean-pool patch embeddings into one vector per track.
    patches = embedding_model(audio_16k)
    embedding = np.mean(patches, axis=0).astype(np.float32)

    loudness = es.LoudnessEBUR128()(np.column_stack([audio_44k, audio_44k]))
    integrated_lufs = float(loudness[2])
    true_peak = float(20.0 * np.log10(max(np.max(np.abs(audio_44k)), 1e-9)))

    return AnalysisResult(
        embedding=embedding,
        integrated_lufs=integrated_lufs,
        true_peak=true_peak,
    )
