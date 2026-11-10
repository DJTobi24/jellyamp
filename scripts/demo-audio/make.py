#!/usr/bin/env python3
"""Generates the audio loops of the in-app demo library.

The demo backend (ios/Packages/JellyfinDemo/Sources/JellyfinDemo) serves a
fictional library whose tracks must be real, decodable audio that nobody owns.
This script synthesizes short musical phrases (plain additive synthesis, no
samples) and encodes each as raw ADTS AAC. ADTS frames are self-contained, and
every phrase starts and ends in silence, so the Swift side builds a track of
any length by concatenating whole loop files — no encoder is needed on the
device, and the result plays through the same streaming path as a real
`.aac` file on a Jellyfin server.

Usage: scripts/demo-audio/make.py   (needs numpy and ffmpeg; rewrites
ios/Packages/JellyfinDemo/Sources/JellyfinDemo/Resources/Loops/*.aac)

The output is committed: the build never runs this script.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import wave

import numpy as np

RATE = 44_100
FRAME = 1024
# 172 AAC frames = 3.994 s: two bars of 4/4 at ~120 bpm. Every loop has the
# same length, so any order of loops keeps the beat.
LOOP_FRAMES = 172
LOOP_SAMPLES = LOOP_FRAMES * FRAME
BEAT = LOOP_SAMPLES / 8
BITRATE = "48k"

OUT = pathlib.Path(__file__).resolve().parents[2] / "ios/Packages/JellyfinDemo/Sources/JellyfinDemo/Resources/Loops"


def hz(midi: float) -> float:
    return 440.0 * 2 ** ((midi - 69) / 12)


def tone(midi: float, start: float, length: float, partials, attack: float, decay: float, level: float = 1.0,
         detune: float = 0.0) -> np.ndarray:
    """One note: `partials` is [(harmonic, amplitude)], times are in beats."""
    out = np.zeros(LOOP_SAMPLES)
    begin = int(start * BEAT)
    count = min(int(length * BEAT), LOOP_SAMPLES - begin)
    if count <= 0:
        return out
    t = np.arange(count) / RATE
    env = np.minimum(1.0, t / max(attack, 1e-4)) * np.exp(-t / decay)
    # Always end the note at zero so nothing clicks at the loop boundary.
    release = min(count, int(0.05 * RATE))
    env[-release:] *= np.linspace(1.0, 0.0, release)
    freq = hz(midi) * (1 + detune)
    signal = sum(amp * np.sin(2 * np.pi * freq * harmonic * t) for harmonic, amp in partials)
    out[begin:begin + count] = level * env * signal
    return out


def stereo(left: np.ndarray, right: np.ndarray) -> np.ndarray:
    data = np.stack([left, right], axis=1)
    # Silence at both ends: the encoder's priming delay shifts the audio by a
    # frame or two, and concatenated loops must meet at zero.
    edge = int(0.02 * RATE)
    data[:edge] *= np.linspace(0.0, 1.0, edge)[:, None]
    tail = int(0.12 * RATE)
    data[-FRAME * 3 - tail:-FRAME * 3] *= np.linspace(1.0, 0.0, tail)[:, None]
    data[-FRAME * 3:] = 0.0
    return data


SINE = [(1, 1.0)]
SOFT = [(1, 1.0), (2, 0.35), (3, 0.12)]
BRIGHT = [(1, 1.0), (2, 0.6), (3, 0.4), (4, 0.25), (5, 0.15), (6, 0.08)]
HOLLOW = [(1, 1.0), (3, 0.45), (5, 0.2), (7, 0.08)]
BELL = [(1, 1.0), (2.76, 0.4), (5.4, 0.18)]


def pad(chord) -> np.ndarray:
    """Ambient: slow, wide chords that swell and fade."""
    left = np.zeros(LOOP_SAMPLES)
    right = np.zeros(LOOP_SAMPLES)
    for index, note in enumerate(chord):
        left += tone(note, 0, 7.6, SOFT, attack=1.2, decay=3.5, level=0.16, detune=-0.002)
        right += tone(note, 0, 7.6, SOFT, attack=1.4, decay=3.5, level=0.16, detune=0.002)
        bell = tone(note + 12, 2 + index, 3.5, BELL, attack=0.01, decay=0.9, level=0.05)
        left += bell * (0.3 + 0.2 * index)
        right += bell * (0.9 - 0.2 * index)
    left += tone(chord[0] - 12, 0, 7.6, SINE, attack=0.8, decay=4.0, level=0.2)
    right += tone(chord[0] - 12, 0, 7.6, SINE, attack=0.8, decay=4.0, level=0.2)
    return stereo(left, right)


def arp(chord) -> np.ndarray:
    """Electronic: sixteenth-note arpeggio over a pulsing bass."""
    left = np.zeros(LOOP_SAMPLES)
    right = np.zeros(LOOP_SAMPLES)
    notes = [chord[0], chord[1], chord[2], chord[1] + 12, chord[2], chord[1], chord[0] + 12, chord[2]]
    for step in range(30):
        note = notes[step % len(notes)] + 12
        voice = tone(note, step * 0.25, 0.5, HOLLOW, attack=0.004, decay=0.12, level=0.13)
        if step % 2 == 0:
            left += voice
            right += voice * 0.5
        else:
            left += voice * 0.5
            right += voice
    for beat in range(8):
        bass = tone(chord[0] - 24, beat, 0.8, BRIGHT, attack=0.005, decay=0.22, level=0.2)
        left += bass
        right += bass
        if beat < 7:
            off = tone(chord[0] - 12, beat + 0.5, 0.4, SOFT, attack=0.005, decay=0.1, level=0.1)
            left += off
            right += off
    return stereo(left, right)


def pluck(chord) -> np.ndarray:
    """Folk: finger-picked pattern."""
    left = np.zeros(LOOP_SAMPLES)
    right = np.zeros(LOOP_SAMPLES)
    pattern = [(0, chord[0] - 12), (0.5, chord[2]), (1, chord[1]), (1.5, chord[2]),
               (2, chord[0]), (2.5, chord[2]), (3, chord[1]), (3.5, chord[2]),
               (4, chord[0] - 12), (4.5, chord[2]), (5, chord[1]), (5.5, chord[2]),
               (6, chord[0]), (6.5, chord[1] + 12), (7, chord[2])]
    for index, (start, note) in enumerate(pattern):
        voice = tone(note, start, 1.6, BRIGHT, attack=0.003, decay=0.38, level=0.17)
        pan = 0.35 + 0.3 * (index % 3) / 2
        left += voice * (1 - pan)
        right += voice * pan
    return stereo(left, right)


def keys(chord) -> np.ndarray:
    """Classical: broken chords with a singing top line."""
    left = np.zeros(LOOP_SAMPLES)
    right = np.zeros(LOOP_SAMPLES)
    for bar in range(2):
        base = bar * 4
        for step, note in enumerate([chord[0] - 12, chord[1] - 12, chord[2] - 12, chord[1] - 12,
                                     chord[0], chord[1] - 12, chord[2] - 12, chord[1] - 12]):
            if base + step * 0.5 >= 7.5:
                break
            voice = tone(note, base + step * 0.5, 1.2, SOFT, attack=0.006, decay=0.5, level=0.13)
            left += voice * 0.8
            right += voice * 0.6
    melody = [(0, chord[2] + 12, 2), (2, chord[1] + 12, 1), (3, chord[2] + 12, 1), (4, chord[0] + 24, 2.5)]
    for start, note, length in melody:
        voice = tone(note, start, length + 0.8, SOFT, attack=0.008, decay=0.9, level=0.17)
        left += voice * 0.6
        right += voice * 0.85
    return stereo(left, right)


def comp(chord) -> np.ndarray:
    """Jazz: walking bass and off-beat chord stabs (seventh chords)."""
    left = np.zeros(LOOP_SAMPLES)
    right = np.zeros(LOOP_SAMPLES)
    walk = [chord[0], chord[1], chord[2], chord[1] + 1, chord[0] + 12, chord[2], chord[1], chord[0] + 2]
    for beat, note in enumerate(walk):
        length = 0.7 if beat == 7 else 0.95
        bass = tone(note - 24, beat, length, [(1, 1.0), (2, 0.5), (3, 0.2)], attack=0.01, decay=0.35, level=0.24)
        left += bass
        right += bass * 0.9
    seventh = chord[0] + 10
    for start in (1.5, 3.5, 5.5):
        for note in (chord[1], chord[2], seventh, chord[0] + 14):
            stab = tone(note, start, 0.9, HOLLOW, attack=0.01, decay=0.22, level=0.075)
            left += stab * 0.5
            right += stab
    for beat in range(7):
        tick = tone(96, beat + (2 / 3 if beat % 2 else 0), 0.2, BELL, attack=0.001, decay=0.03, level=0.02)
        left += tick
        right += tick * 0.6
    return stereo(left, right)


def drive(chord) -> np.ndarray:
    """Rock: eighth-note power chords with a little grit."""
    left = np.zeros(LOOP_SAMPLES)
    right = np.zeros(LOOP_SAMPLES)
    for step in range(15):
        accent = 1.0 if step % 4 == 0 else 0.7
        for note in (chord[0] - 12, chord[0] - 5, chord[0]):
            left += tone(note, step * 0.5, 0.48, BRIGHT, attack=0.004, decay=0.2, level=0.12 * accent, detune=-0.003)
            right += tone(note, step * 0.5, 0.48, BRIGHT, attack=0.004, decay=0.2, level=0.12 * accent, detune=0.003)
    for start, note in ((0, chord[2] + 12), (3, chord[1] + 12), (4, chord[2] + 12), (6, chord[0] + 12)):
        lead = tone(note, start, 1.8, HOLLOW, attack=0.02, decay=0.7, level=0.1)
        left += lead * 0.7
        right += lead
    grit = np.tanh(np.stack([left, right], axis=1) * 2.2) / 2.2
    return stereo(grit[:, 0], grit[:, 1])


# Four chords per style (root-position triads as MIDI notes); the Swift side
# orders them into a "song".
STYLES = {
    "ambient": (pad, [(57, 60, 64), (53, 57, 60), (48, 52, 55), (55, 59, 62)]),        # Am F C G
    "electronic": (arp, [(50, 53, 57), (46, 50, 53), (53, 57, 60), (48, 52, 55)]),     # Dm Bb F C
    "folk": (pluck, [(55, 59, 62), (52, 55, 59), (48, 52, 55), (50, 54, 57)]),         # G Em C D
    "classical": (keys, [(60, 64, 67), (57, 60, 64), (53, 57, 60), (55, 59, 62)]),     # C Am F G
    "jazz": (comp, [(50, 53, 57), (55, 59, 62), (48, 52, 55), (57, 61, 64)]),          # Dm7 G7 C A7
    "rock": (drive, [(52, 55, 59), (48, 52, 55), (55, 59, 62), (50, 54, 57)]),         # Em C G D
}


def encode(data: np.ndarray, target: pathlib.Path) -> None:
    peak = float(np.max(np.abs(data)))
    if peak > 0.89:
        data = data * (0.89 / peak)
    pcm = (data * 32767).astype("<i2")
    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "loop.wav"
        with wave.open(str(wav), "wb") as handle:
            handle.setnchannels(2)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes(pcm.tobytes())
        subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(wav), "-c:a", "aac", "-profile:a", "aac_low",
             "-b:a", BITRATE, "-ar", str(RATE), "-ac", "2", "-bitexact", "-f", "adts", str(target)],
            check=True,
        )


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.aac"):
        old.unlink()
    total = 0
    for style, (render, chords) in STYLES.items():
        for index, chord in enumerate(chords):
            target = OUT / f"{style}-{index}.aac"
            encode(render(chord), target)
            total += target.stat().st_size
    print(f"wrote {len(STYLES) * 4} loops, {total / 1024:.0f} kB, to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
