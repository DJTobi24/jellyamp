"""Extractor interface shared by all analysis backends (ADR-0004)."""

from dataclasses import dataclass
from typing import Protocol

import numpy as np


class AnalysisError(RuntimeError):
    """A clip could not be analyzed (undecodable, silent, too short)."""


@dataclass
class AnalysisResult:
    embedding: np.ndarray
    # None when the clip has no measurable loudness (e.g. digital silence).
    integrated_lufs: float | None
    true_peak: float | None


class Extractor(Protocol):
    """Turns an encoded audio clip into an embedding + loudness.

    `name` and `version` are stored per track; when the active extractor's
    `ident` differs from a track's stored one the scanner re-analyzes it,
    because embeddings from different extractors are not comparable.
    """

    name: str
    version: str
    dim: int
    # True when dimensions are heterogeneous hand-crafted features that must
    # be standardized across the library before cosine distance is meaningful.
    standardize: bool
    # Optional per-dimension weights applied after standardization.
    weights: np.ndarray | None

    def analyze(self, audio_bytes: bytes) -> AnalysisResult: ...


def ident(extractor: Extractor) -> str:
    return f"{extractor.name}/{extractor.version}"
