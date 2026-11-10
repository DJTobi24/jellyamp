"""Selects the analysis backend from configuration (ADR-0004).

`ANALYSIS_BACKEND`:
- `auto` (default): Essentia/MusiCNN when installed *and* its model file is
  present, otherwise the built-in DSP backend, otherwise none.
- `dsp` / `essentia`: require that backend; startup fails with the reason if
  it cannot run (an explicit choice must not silently degrade).
- `none`: never analyze; the API serves whatever is already stored.
"""

import logging

from jellyamp_server.analysis import audio, essentia_backend
from jellyamp_server.analysis.base import Extractor
from jellyamp_server.analysis.dsp import DSPExtractor
from jellyamp_server.config import ConfigError, Settings

logger = logging.getLogger(__name__)


def _problems(config: Settings) -> tuple[str | None, str | None]:
    """(why essentia cannot run, why ffmpeg cannot run); None = it can."""
    essentia_problem = essentia_backend.unavailable_reason(config.musicnn_model_path)
    ffmpeg_problem = (
        None
        if audio.ffmpeg_available(config.ffmpeg_path)
        else f"ffmpeg binary {config.ffmpeg_path!r} not found on PATH"
    )
    return essentia_problem, ffmpeg_problem


def preflight(config: Settings) -> None:
    """Raises ConfigError when an explicitly requested backend cannot run."""
    essentia_problem, ffmpeg_problem = _problems(config)
    if config.analysis_backend == "essentia" and essentia_problem:
        raise ConfigError(f"ANALYSIS_BACKEND=essentia but {essentia_problem}")
    if config.analysis_backend == "dsp" and ffmpeg_problem:
        raise ConfigError(f"ANALYSIS_BACKEND=dsp but {ffmpeg_problem}")


def select_extractor(config: Settings) -> Extractor | None:
    backend = config.analysis_backend
    if backend == "none":
        return None
    preflight(config)
    essentia_problem, ffmpeg_problem = _problems(config)
    ffmpeg_ok = ffmpeg_problem is None

    if backend == "essentia":
        return essentia_backend.EssentiaExtractor(config.musicnn_model_path, config.ffmpeg_path)
    if backend == "dsp":
        return DSPExtractor(config.ffmpeg_path)

    # auto
    if essentia_problem is None:
        return essentia_backend.EssentiaExtractor(config.musicnn_model_path, config.ffmpeg_path)
    if essentia_backend.ESSENTIA_AVAILABLE:
        # Installed but unusable is worth a line: the user built the full image.
        logger.warning("essentia backend unavailable (%s); using DSP backend", essentia_problem)
    if ffmpeg_ok:
        return DSPExtractor(config.ffmpeg_path)
    logger.warning("no analysis backend available (%s); analysis disabled", ffmpeg_problem)
    return None
