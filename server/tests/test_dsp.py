"""DSP analysis backend against ffmpeg-generated audio.

The five "genres" are the synthetic voices of scripts/dev-jellyfin's test
library (each with a distinct spectral/rhythmic character), so passing here
predicts sensible behaviour of the end-to-end integration test.
"""

import shutil
import subprocess

import numpy as np
import pytest

from jellyamp_server.analysis import audio
from jellyamp_server.analysis.base import AnalysisError
from jellyamp_server.analysis.dsp import EMBEDDING_DIM, SAMPLE_RATE, DSPExtractor, embed
from jellyamp_server.sonic.index import LibraryIndex
from jellyamp_server.store import TrackRecord

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")

# genre -> lavfi graph, same as scripts/dev-jellyfin/make-library.py
VOICES = {
    "Ambient": "sine=f={f}:d={d},volume=0.5[a];anoisesrc=d={d}:c=brown:a=0.25:seed=1[n];"
    "[a][n]amix=2,lowpass=f=900",
    "Electronic": "sine=f={f}:d={d},tremolo=f=8:d=0.9[a];"
    "anoisesrc=d={d}:c=white:a=0.05:seed=1,highpass=f=6000[n];[a][n]amix=2",
    "Rock": "sine=f={f}:d={d},acrusher=bits=4:mix=0.6:samples=8[a];"
    "anoisesrc=d={d}:c=pink:a=0.2:seed=1[n];[a][n]amix=2",
    "Classical": "sine=f={f}:d={d}[a];sine=f={f2}:d={d},volume=0.5[b];"
    "[a][b]amix=2,vibrato=f=5:d=0.2",
    "Jazz": "sine=f={f}:d={d},tremolo=f=3:d=0.5[a];sine=f={f3}:d={d},volume=0.4[b];"
    "[a][b]amix=2,lowpass=f=3000",
}
FREQUENCIES = (196, 262, 330, 440)
FLOAT_WAV = ("-c:a", "pcm_f32le", "-f", "wav")


def voice(genre: str, frequency: int, seconds: int) -> str:
    return VOICES[genre].format(
        f=frequency, f2=round(frequency * 1.5), f3=round(frequency * 1.26), d=seconds
    )


def render(graph: str, *codec: str) -> bytes:
    """Runs a lavfi filter graph through ffmpeg and returns the encoded bytes."""
    command = ["ffmpeg", "-v", "error", "-filter_complex", graph, *(codec or FLOAT_WAV)]
    return subprocess.run([*command, "pipe:1"], capture_output=True, check=True).stdout


def stereo_sine(dbfs: float, seconds: int = 6, frequency: int = 1000) -> bytes:
    # lavfi's sine peaks at 1/8 (−18.06 dBFS); scale to the requested peak.
    gain = dbfs + 18.0618
    return render(f"sine=f={frequency}:d={seconds},volume={gain}dB,pan=stereo|c0=c0|c1=c0")


@pytest.fixture(scope="module")
def extractor() -> DSPExtractor:
    return DSPExtractor()


@pytest.fixture(scope="module")
def genre_library(extractor) -> list[TrackRecord]:
    records = []
    for genre in VOICES:
        for frequency in FREQUENCIES:
            clip = render(voice(genre, frequency, 10), "-c:a", "flac", "-f", "flac")
            records.append(
                TrackRecord(
                    f"{genre}-{frequency}", extractor.analyze(clip).embedding, genres=[genre]
                )
            )
    return records


def test_embedding_has_fixed_dimension_and_is_finite(genre_library):
    for record in genre_library:
        assert record.embedding.shape == (EMBEDDING_DIM,)
        assert record.embedding.dtype == np.float32
        assert np.all(np.isfinite(record.embedding))


def test_embedding_is_deterministic(extractor):
    clip = render(voice("Rock", 220, 6), "-f", "mp3", "-b:a", "192k")
    first = extractor.analyze(clip)
    second = extractor.analyze(clip)
    assert np.array_equal(first.embedding, second.embedding)
    assert first.integrated_lufs == second.integrated_lufs


def test_embedding_ignores_playback_level(extractor):
    loud = extractor.analyze(render(voice("Jazz", 262, 6)))
    quiet = extractor.analyze(render(voice("Jazz", 262, 6) + ",volume=-12dB"))
    assert np.allclose(loud.embedding, quiet.embedding, atol=0.02)
    assert loud.integrated_lufs - quiet.integrated_lufs == pytest.approx(12.0, abs=0.3)


# Noise-based or strongly modulated voices: unmistakable at any pitch.
DISTINCT = {"Ambient", "Electronic", "Rock"}
# Both are bare two-sine chords; they differ only by Jazz's 3 Hz tremolo.
TWO_TONE = {"Classical", "Jazz"}


def test_distinct_genres_are_each_others_nearest_neighbours(extractor, genre_library):
    """For the three distinct voices every neighbour is the same genre."""
    index = LibraryIndex(genre_library, standardize=True, weights=extractor.weights)
    per_genre = len(FREQUENCIES) - 1
    for record in index.records:
        neighbours = index.nearest(record.embedding, per_genre, index.mask([record.item_id]))
        genres = [n.genres[0] for n, _ in neighbours]
        if record.genres[0] in DISTINCT:
            assert genres == record.genres * per_genre, record.item_id
        else:
            # Across an octave of pitch the two-tone voices may interleave,
            # but they never drift towards the noise/tremolo voices.
            assert set(genres) <= TWO_TONE, record.item_id


def test_every_genre_is_separable_by_its_centroid(extractor, genre_library):
    """All five genres are cleanly separable: each track is closest to the
    centroid of its own genre's *other* tracks (leave-one-out), which is how
    album/artist similarity and mixes use the space."""
    index = LibraryIndex(genre_library, standardize=True, weights=extractor.weights)
    for record in index.records:
        distances = {}
        for genre in VOICES:
            others = [
                o for o in index.records if o.genres == [genre] and o.item_id != record.item_id
            ]
            centroid = index.centroid(others)
            distances[genre] = 1.0 - float(centroid @ record.embedding) / np.linalg.norm(centroid)
        assert min(distances, key=distances.get) == record.genres[0], (record.item_id, distances)


def test_same_recording_in_different_codecs_is_nearly_identical(extractor, genre_library):
    flac = {r.item_id: r for r in genre_library}["Rock-262"].embedding
    mp3 = extractor.analyze(render(voice("Rock", 262, 10), "-f", "mp3", "-b:a", "128k")).embedding
    other = {r.item_id: r for r in genre_library}["Ambient-262"].embedding
    assert np.linalg.norm(flac - mp3) < 0.1 * np.linalg.norm(flac - other)


def test_loudness_of_reference_tone(extractor):
    # EBU Tech 3341: a stereo 1 kHz sine at −23 dBFS reads −23.0 LUFS.
    result = extractor.analyze(stereo_sine(-23.0))
    assert result.integrated_lufs == pytest.approx(-23.0, abs=0.3)
    assert result.true_peak == pytest.approx(-23.0, abs=0.3)


def test_loudness_tracks_level(extractor):
    quiet = extractor.analyze(stereo_sine(-30.0))
    loud = extractor.analyze(stereo_sine(-12.0))
    assert loud.integrated_lufs - quiet.integrated_lufs == pytest.approx(18.0, abs=0.3)
    assert loud.true_peak == pytest.approx(-12.0, abs=0.3)


def test_truncated_clip_still_decodes(extractor):
    """The scanner cuts the transcode after N bytes, mid-frame."""
    clip = render(voice("Electronic", 330, 20), "-f", "mp3", "-b:a", "192k")
    cut = clip[: len(clip) // 2 + 123]
    decoded = audio.decode(cut)
    assert decoded.duration == pytest.approx(10.0, abs=0.5)
    assert extractor.analyze(cut).embedding.shape == (EMBEDDING_DIM,)


def test_silence_is_rejected(extractor):
    with pytest.raises(AnalysisError, match="silent"):
        extractor.analyze(render("anullsrc=d=5"))


def test_too_short_clip_is_rejected():
    with pytest.raises(AnalysisError, match="too short"):
        embed(np.ones(SAMPLE_RATE, dtype=np.float32))


def test_garbage_is_rejected(extractor):
    with pytest.raises(AnalysisError):
        extractor.analyze(b"this is not audio" * 100)
    with pytest.raises(AnalysisError, match="empty"):
        extractor.analyze(b"")


def test_missing_ffmpeg_binary_is_reported():
    with pytest.raises(AnalysisError, match="not found"):
        audio.decode(b"x", ffmpeg="/nonexistent/ffmpeg")
