"""Decode audio with the ffmpeg binary and measure EBU R128 loudness.

One ffmpeg process does both: the `ebur128` filter measures the original
(pre-downmix) signal and logs a summary to stderr, then the audio is
resampled to mono PCM on stdout for feature extraction. Using the binary
instead of Python bindings keeps the slim image dependency-free beyond
`apt install ffmpeg` and supports every codec Jellyfin can hand us.
"""

import re
import shutil
import subprocess
from dataclasses import dataclass

import numpy as np

from jellyamp_server.analysis.base import AnalysisError

# Below this ffmpeg reports its absolute gate (-70 LUFS): no real programme.
_SILENCE_LUFS = -69.0

_INTEGRATED = re.compile(r"\bI:\s+(-?\d+(?:\.\d+)?|-?inf|nan)\s+LUFS")
_PEAK = re.compile(r"\bPeak:\s+(-?\d+(?:\.\d+)?|-?inf|nan)\s+dBFS")


@dataclass
class DecodedAudio:
    samples: np.ndarray  # mono float32 in [-1, 1]
    sample_rate: int
    integrated_lufs: float | None
    true_peak: float | None

    @property
    def duration(self) -> float:
        return len(self.samples) / self.sample_rate


def ffmpeg_available(ffmpeg: str = "ffmpeg") -> bool:
    return shutil.which(ffmpeg) is not None


def parse_loudness(stderr: str) -> tuple[float | None, float | None]:
    """Extracts (integrated LUFS, true peak dBFS) from an ebur128 summary."""
    # The summary is the last block; per-frame log lines also contain "I:".
    summary = stderr[stderr.rfind("Summary:") :] if "Summary:" in stderr else ""
    integrated = _number(_INTEGRATED.search(summary))
    peak = _number(_PEAK.search(summary))
    if integrated is None or integrated <= _SILENCE_LUFS:
        return None, None
    return integrated, peak


def _number(match: re.Match | None) -> float | None:
    if match is None:
        return None
    value = float(match.group(1))
    return value if np.isfinite(value) else None


def decode(
    audio_bytes: bytes,
    *,
    ffmpeg: str = "ffmpeg",
    sample_rate: int = 22050,
    max_seconds: float | None = None,
    timeout: float = 300.0,
) -> DecodedAudio:
    """Decodes an encoded clip (any container ffmpeg can sniff) from memory."""
    if not audio_bytes:
        raise AnalysisError("empty audio clip")
    command = [ffmpeg, "-hide_banner", "-nostats", "-loglevel", "info"]
    if max_seconds:
        command += ["-t", f"{max_seconds:g}"]
    command += [
        "-i", "pipe:0",
        "-vn",  # embedded cover art is a video stream
        "-af",
        "ebur128=peak=true,"
        f"aresample={sample_rate},aformat=sample_fmts=flt:channel_layouts=mono",
        "-f", "f32le",
        "pipe:1",
    ]  # fmt: skip
    try:
        process = subprocess.run(  # noqa: S603 - fixed argv, no shell
            command, input=audio_bytes, capture_output=True, timeout=timeout, check=False
        )
    except FileNotFoundError as error:
        raise AnalysisError(f"ffmpeg binary {ffmpeg!r} not found") from error
    except subprocess.TimeoutExpired as error:
        raise AnalysisError("ffmpeg timed out decoding clip") from error

    stderr = process.stderr.decode("utf-8", errors="replace")
    pcm = process.stdout
    # A truncated clip makes ffmpeg exit non-zero at EOF although everything
    # before the cut decoded fine, so judge by the PCM we got, not the code.
    if len(pcm) < 4:
        last_line = stderr.strip().splitlines()[-1] if stderr.strip() else "no output"
        raise AnalysisError(f"ffmpeg could not decode clip: {last_line}")
    # Float PCM: no requantization, so quiet recordings keep their detail.
    samples = np.frombuffer(pcm[: len(pcm) // 4 * 4], dtype="<f4")
    if not np.all(np.isfinite(samples)):
        # Broken float sources can carry NaN/Inf samples; treat them as silence.
        samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
    integrated, peak = parse_loudness(stderr)
    return DecodedAudio(samples, sample_rate, integrated, peak)
