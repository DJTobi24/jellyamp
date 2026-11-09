"""Built-in DSP analysis backend: ffmpeg + numpy, no ML model.

Produces a fixed 75-dimensional timbre/rhythm descriptor per track:

| dims | group    | content                                                      |
|------|----------|--------------------------------------------------------------|
| 13   | timbre   | MFCC 1–13 means (c0 dropped: level-invariant)                |
| 13   | texture  | MFCC 1–13 standard deviations                                |
| 13   | motion   | delta-MFCC standard deviations                               |
| 12   | shape    | centroid, bandwidth, rolloff, flatness, ZCR, flux (mean+std) |
| 8    | balance  | energy share of 8 mel band groups (sub-bass … air)           |
| 16   | rhythm   | onset rate, tempo, pulse clarity, 6 amplitude- and 4         |
|      |          | brightness-modulation bands, loudness variation,             |
|      |          | low-energy ratio, crest factor                               |

The signal is normalized to unit RMS first, so the same recording at a
different volume yields the same vector. Everything is plain deterministic
arithmetic: the same clip always gives the same embedding.

The dimensions are heterogeneous (octaves, ratios, cepstra), so the similarity
index standardizes them across the library (`standardize = True`) and applies
`weights` so that no group dominates just because it has more dimensions.
This is far cruder than a learned embedding (MusiCNN), but it needs nothing
besides ffmpeg, runs ~50× realtime on one core, and reliably groups tracks by
timbre, brightness, texture and pulse — which is what "sonically similar"
means to a listener.
"""

import numpy as np

from jellyamp_server.analysis import audio
from jellyamp_server.analysis.base import AnalysisError, AnalysisResult

SAMPLE_RATE = 22050
N_FFT = 1024
HOP = 512
N_MELS = 40
N_MFCC = 13
FRAME_RATE = SAMPLE_RATE / HOP
MIN_SECONDS = 3.0
# Feature extraction is capped (loudness is still measured over everything
# decoded) so whole-track mode cannot blow up memory on a 2-hour DJ set.
MAX_FEATURE_SECONDS = 600.0

# (name, size, weight). Rhythm/dynamics get extra weight: few dimensions, but
# what a listener notices first (a pulsing pad is not a steady drone).
_GROUPS: list[tuple[str, int, float]] = [
    ("timbre", N_MFCC, 1.0),
    ("texture", N_MFCC, 0.5),
    ("motion", N_MFCC, 0.5),
    ("shape", 12, 1.0),
    ("balance", 8, 0.5),
    ("rhythm", 16, 1.5),
]
# Cepstral groups are liftered: low coefficients describe the broad spectral
# envelope (timbre), high ones increasingly follow pitch and harmonic detail.
_LIFTERED = {"timbre", "texture", "motion"}
_LIFTER_EXPONENT = 0.5
EMBEDDING_DIM = sum(size for _, size, _ in _GROUPS)

# Log floor ≈ −56 dB below a full-band unit-RMS signal. Everything quieter
# (dither, codec noise floors, an MP3's lowpass) is treated as "nothing", so
# the FLAC and the MP3 of one recording land on (nearly) the same vector.
_LOG_FLOOR = 1e-3

# Rough per-group magnitudes so raw vectors are sensibly scaled even before
# library standardization kicks in (tiny libraries).
_PRIOR_SCALE = np.concatenate(
    [
        np.full(N_MFCC, 0.1),
        np.full(N_MFCC, 0.2),
        np.full(N_MFCC, 0.5),
        np.ones(12),
        np.full(8, 0.25),
        np.ones(16),
    ]
).astype(np.float32)


def _group_weights() -> np.ndarray:
    """Per-dimension weights; each group's weights have L2 norm = its weight,
    so a group's influence does not grow with its number of dimensions."""
    parts = []
    for name, size, weight in _GROUPS:
        profile = (
            np.arange(1, size + 1) ** -_LIFTER_EXPONENT if name in _LIFTERED else np.ones(size)
        )
        parts.append(weight * profile / np.linalg.norm(profile))
    return np.concatenate(parts).astype(np.float32)


def _hz_to_mel(hz: np.ndarray | float) -> np.ndarray:
    return 2595.0 * np.log10(1.0 + np.asarray(hz, dtype=np.float64) / 700.0)


def _mel_to_hz(mel: np.ndarray) -> np.ndarray:
    return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)


def _mel_filterbank() -> np.ndarray:
    """Triangular HTK-mel filters, shape (N_MELS, N_FFT // 2 + 1)."""
    fft_freqs = np.fft.rfftfreq(N_FFT, 1.0 / SAMPLE_RATE)
    edges = _mel_to_hz(np.linspace(_hz_to_mel(30.0), _hz_to_mel(SAMPLE_RATE / 2), N_MELS + 2))
    bank = np.zeros((N_MELS, len(fft_freqs)))
    for band in range(N_MELS):
        low, center, high = edges[band : band + 3]
        rising = (fft_freqs - low) / (center - low)
        falling = (high - fft_freqs) / (high - center)
        bank[band] = np.clip(np.minimum(rising, falling), 0.0, None)
    return bank


def _dct_matrix() -> np.ndarray:
    """Orthonormal DCT-II rows 1…N_MFCC over N_MELS inputs."""
    n = np.arange(N_MELS)
    k = np.arange(1, N_MFCC + 1)[:, None]
    return np.sqrt(2.0 / N_MELS) * np.cos(np.pi * k * (2 * n + 1) / (2 * N_MELS))


_FFT_FREQS = np.fft.rfftfreq(N_FFT, 1.0 / SAMPLE_RATE)
_MEL_BANK = _mel_filterbank()
_DCT = _dct_matrix()
_WINDOW = np.hanning(N_FFT)


def _power_spectrogram(samples: np.ndarray) -> np.ndarray:
    frames = np.lib.stride_tricks.sliding_window_view(samples, N_FFT)[::HOP]
    power = np.empty((len(frames), N_FFT // 2 + 1), dtype=np.float64)
    # Chunked so the complex FFT temporary stays small.
    for start in range(0, len(frames), 1024):
        chunk = frames[start : start + 1024] * _WINDOW
        power[start : start + 1024] = np.abs(np.fft.rfft(chunk, axis=1)) ** 2
    return power


def _mean_std(values: np.ndarray) -> tuple[float, float]:
    return float(np.mean(values)), float(np.std(values))


_MODULATION_EDGES = (0.5, 1.0, 2.0, 4.0, 8.0, 16.0, FRAME_RATE / 2 + 1e-9)
_PITCH_MODULATION_EDGES = (0.5, 2.0, 4.0, 8.0, 16.0)


def _modulation_depth(track: np.ndarray, edges: tuple[float, ...]) -> np.ndarray:
    """RMS fluctuation of a per-frame track within each modulation-rate band."""
    size = 1 << int(np.ceil(np.log2(len(track))))
    spectrum = np.abs(np.fft.rfft(track - track.mean(), size)) ** 2
    rates = np.fft.rfftfreq(size, 1.0 / FRAME_RATE)
    energy = np.array(
        [
            spectrum[(rates >= low) & (rates < high)].sum()
            for low, high in zip(edges[:-1], edges[1:], strict=True)
        ]
    )
    # Parseval: band energy of the spectrum → RMS of the band-limited track.
    return np.sqrt(2.0 * energy / (len(track) * size))


def _rhythm_features(
    onset_env: np.ndarray, frame_energy: np.ndarray, centroid_octaves: np.ndarray, x: np.ndarray
) -> list[float]:
    duration = len(onset_env) / FRAME_RATE
    centered = onset_env - onset_env.mean()

    # Onset rate: local maxima that clearly stand out. The absolute margin
    # keeps the random flicker of noise and sustained tones from counting.
    threshold = onset_env.mean() + max(onset_env.std(), 0.02)
    middle = onset_env[1:-1]
    peaks = (middle > onset_env[:-2]) & (middle >= onset_env[2:]) & (middle > threshold)
    onset_rate = float(peaks.sum()) / max(duration, 1e-6)

    # Tempo from the autocorrelation of the onset envelope (40–220 BPM),
    # with a log-normal preference around 120 BPM to settle octave ties.
    size = 1 << int(np.ceil(np.log2(2 * len(centered))))
    spectrum = np.abs(np.fft.rfft(centered, size)) ** 2
    autocorr = np.fft.irfft(spectrum)[: len(centered)]
    tempo_feature = 0.0
    clarity = 0.0
    if autocorr[0] > 1e-12:
        autocorr = autocorr / autocorr[0]
        low_lag = int(np.floor(60.0 * FRAME_RATE / 220.0))
        high_lag = min(int(np.ceil(60.0 * FRAME_RATE / 40.0)), len(autocorr) - 1)
        if high_lag > low_lag:
            lags = np.arange(low_lag, high_lag + 1)
            bpm = 60.0 * FRAME_RATE / lags
            prior = np.exp(-0.5 * (np.log2(bpm / 120.0)) ** 2)
            best = int(np.argmax(autocorr[lags] * prior))
            clarity = float(np.clip(autocorr[lags][best], 0.0, 1.0))
            # A tempo estimate is only as meaningful as the pulse is clear,
            # and without onsets there is no pulse at all.
            if onset_rate < 0.2:
                clarity = 0.0
            tempo_feature = float(np.log2(bpm[best] / 120.0)) * clarity

    # Amplitude modulation: how deeply the level pulses at rates from slow
    # swells (0.5 Hz) through beat rates (1–4 Hz) to tremolo and rolls
    # (>8 Hz), relative to the mean level. A steady drone scores ~0
    # everywhere, a four-on-the-floor kick peaks around 2 Hz.
    envelope = np.sqrt(frame_energy)
    modulation = _modulation_depth(envelope, _MODULATION_EDGES) / max(float(envelope.mean()), 1e-9)
    # Brightness modulation: how much the spectral centroid moves (in
    # octaves) at each rate — vibrato, filter sweeps, melodic motion.
    pitch_modulation = _modulation_depth(centroid_octaves, _PITCH_MODULATION_EDGES)

    log_energy = 10.0 * np.log10(frame_energy + 1e-10)
    loudness_variation = float(np.std(log_energy)) / 10.0
    low_energy_ratio = float(np.mean(frame_energy < 0.5 * frame_energy.mean()))
    crest = float(np.log10(max(float(np.max(np.abs(x))), 1e-6)))  # x has unit RMS

    return [
        onset_rate / 5.0,
        tempo_feature,
        clarity,
        *modulation.tolist(),
        *(pitch_modulation * 4.0).tolist(),
        loudness_variation,
        low_energy_ratio,
        crest,
    ]


def embed(samples: np.ndarray) -> np.ndarray:
    """Mono float PCM at SAMPLE_RATE → EMBEDDING_DIM-dimensional float32 vector."""
    x = np.asarray(samples, dtype=np.float64)[: int(MAX_FEATURE_SECONDS * SAMPLE_RATE)]
    if len(x) < MIN_SECONDS * SAMPLE_RATE:
        raise AnalysisError(
            f"clip too short for analysis ({len(x) / SAMPLE_RATE:.1f}s < {MIN_SECONDS:.0f}s)"
        )
    x = x - x.mean()
    rms = float(np.sqrt(np.mean(x**2)))
    if rms < 1e-4:
        raise AnalysisError("clip is silent")
    x = x / rms

    power = _power_spectrogram(x)
    frame_energy = power.sum(axis=1) + 1e-10
    mel = power @ _MEL_BANK.T
    log_mel = np.log(mel + _LOG_FLOOR)

    mfcc = log_mel @ _DCT.T
    delta = (mfcc[4:] - mfcc[:-4]) / 4.0

    # Spectral-shape statistics over frames that actually carry signal, so
    # pauses do not drag the centroid towards the noise floor.
    active = frame_energy > 1e-3 * frame_energy.mean()
    if active.sum() < 8:
        active = np.ones_like(active)
    p = power[active]
    energy = frame_energy[active]
    centroid = (p @ _FFT_FREQS) / energy
    # Full-length centroid track (inactive frames hold the mean) for the
    # brightness-modulation features.
    centroid_track = np.full(len(frame_energy), np.log2(max(float(centroid.mean()), 20.0)))
    centroid_track[active] = np.log2(np.maximum(centroid, 20.0))
    spread = np.sqrt(np.clip((p @ _FFT_FREQS**2) / energy - centroid**2, 0.0, None))
    cumulative = np.cumsum(p, axis=1)
    rolloff = _FFT_FREQS[np.argmax(cumulative >= 0.85 * cumulative[:, -1:], axis=1)]
    floored = mel[active] + _LOG_FLOOR
    flatness = np.exp(np.mean(np.log(floored), axis=1)) / np.mean(floored, axis=1)

    frames = np.lib.stride_tricks.sliding_window_view(x, N_FFT)[::HOP]
    zcr = np.mean(np.abs(np.diff(np.signbit(frames), axis=1)), axis=1)[active]

    # Onset envelope: positive spectral flux on a compressed mel spectrum.
    # log1p relative to the average band level is logarithmic for the bands
    # that carry the music and ~linear (i.e. negligible) near the noise
    # floor, so flicker in empty bands does not masquerade as onsets.
    compressed = np.log1p(10.0 * mel / mel.mean())
    onset_env = np.clip(np.diff(compressed, axis=0), 0.0, None).mean(axis=1)

    shape = [
        *_mean_std(np.log2(np.maximum(centroid, 20.0) / 1000.0)),
        *_mean_std(np.log2(np.maximum(spread, 20.0) / 1000.0)),
        *_mean_std(np.log2(np.maximum(rolloff, 20.0) / 1000.0)),
        *_mean_std(np.log10(flatness)),
        *_mean_std(zcr * 4.0),
        *_mean_std(onset_env),
    ]

    band_energy = mel.mean(axis=0).reshape(8, N_MELS // 8).sum(axis=1)
    balance = np.log(band_energy / band_energy.sum() + 1e-4)

    vector = np.concatenate(
        [
            mfcc.mean(axis=0),
            mfcc.std(axis=0),
            delta.std(axis=0),
            np.array(shape),
            balance,
            np.array(_rhythm_features(onset_env, frame_energy, centroid_track, x)),
        ]
    ).astype(np.float32)
    vector = vector * _PRIOR_SCALE
    if not np.all(np.isfinite(vector)):
        raise AnalysisError("analysis produced non-finite features")
    return vector


class DSPExtractor:
    name = "dsp"
    # Bump when the feature layout or any constant above changes: stored
    # embeddings from the previous version are then re-analyzed.
    version = "1"
    dim = EMBEDDING_DIM
    standardize = True

    def __init__(self, ffmpeg: str = "ffmpeg"):
        self._ffmpeg = ffmpeg
        self.weights: np.ndarray | None = _group_weights()

    def analyze(self, audio_bytes: bytes) -> AnalysisResult:
        decoded = audio.decode(audio_bytes, ffmpeg=self._ffmpeg, sample_rate=SAMPLE_RATE)
        return AnalysisResult(
            embedding=embed(decoded.samples),
            integrated_lufs=decoded.integrated_lufs,
            true_peak=decoded.true_peak,
        )
