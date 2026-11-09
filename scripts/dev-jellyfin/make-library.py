#!/usr/bin/env python3
"""Generate a small, fully synthetic (license-free) tagged music library.

Used by scripts/dev-jellyfin/up.sh to give a throwaway Jellyfin server real
content for integration tests, UI tests and screenshots. Every "genre" gets a
distinct spectral character so sonic analysis has something to tell apart.

Usage: make-library.py <output-dir> [--seconds 30]
"""
import argparse
import subprocess
import sys
from pathlib import Path

# genre -> ffmpeg lavfi audio graph template ({f} = base frequency, {d} = seconds)
VOICES = {
    "Ambient": "sine=f={f}:d={d},volume=0.5[a];anoisesrc=d={d}:c=brown:a=0.25[n];[a][n]amix=2,lowpass=f=900",
    "Electronic": "sine=f={f}:d={d},tremolo=f=8:d=0.9[a];anoisesrc=d={d}:c=white:a=0.05,highpass=f=6000[n];[a][n]amix=2",
    "Rock": "sine=f={f}:d={d},acrusher=bits=4:mix=0.6:samples=8[a];anoisesrc=d={d}:c=pink:a=0.2[n];[a][n]amix=2",
    "Classical": "sine=f={f}:d={d}[a];sine=f={f}*1.5:d={d},volume=0.5[b];[a][b]amix=2,vibrato=f=5:d=0.2",
    "Jazz": "sine=f={f}:d={d},tremolo=f=3:d=0.5[a];sine=f={f}*1.26:d={d},volume=0.4[b];[a][b]amix=2,lowpass=f=3000",
}

# (artist, album, year, genre, extension, cover colours, [track titles])
ALBUMS = [
    ("Aurora Drift", "Low Tide", 1994, "Ambient", "flac", ("0x0b3d5c", "0x7fd1ff"),
     ["Harbour Lights", "Slow Water", "Tidal Sleep", "Morning Fog"]),
    ("Aurora Drift", "Night Maps", 2003, "Ambient", "mp3", ("0x1a1a40", "0x9b5de5"),
     ["Polaris", "Dead Reckoning", "Meridian"]),
    ("Neon Circuit", "Voltage", 2016, "Electronic", "mp3", ("0xff006e", "0x3a0ca3"),
     ["Power On", "Gridlock", "Arc Flash", "Standby", "Overclock"]),
    ("Neon Circuit", "Afterimage", 2021, "Electronic", "m4a", ("0x00f5d4", "0x00296b"),
     ["Phosphor", "Persistence", "Scanline"]),
    ("The Granite Saints", "Quarry Songs", 1978, "Rock", "mp3", ("0x6a040f", "0xffba08"),
     ["Blast Line", "Hard Hat Blues", "Gravel Road", "Dust and Diesel"]),
    ("The Granite Saints", "Second Shift", 1985, "Rock", "flac", ("0x370617", "0xe85d04"),
     ["Clock In", "Overtime", "Last Bus Home"]),
    ("Halden Quartet", "Chamber Works", 1962, "Classical", "flac", ("0xf1faee", "0xa8dadc"),
     ["Allegro in D", "Adagio", "Scherzo", "Finale"]),
    ("Blue Hour Trio", "Kind of Late", 1959, "Jazz", "ogg", ("0x03045e", "0x48cae4"),
     ["Last Call", "Rain on Ninth", "Slow Train"]),
    ("Blue Hour Trio", "Live at the Cellar", 2010, "Jazz", "mp3", ("0x14213d", "0xfca311"),
     ["Set One", "Set Two", "Encore"]),
    ("Various Artists", "Jellyamp Sampler", 2024, "Electronic", "mp3", ("0x2b2d42", "0xef233c"),
     ["Sampler Intro", "Sampler Outro"]),
]

CODECS = {
    "mp3": ["-c:a", "libmp3lame", "-b:a", "192k"],
    "flac": ["-c:a", "flac"],
    "m4a": ["-c:a", "aac", "-b:a", "192k"],
    "ogg": ["-c:a", "libvorbis", "-q:a", "5"],
}

LRC = """[00:00.00]This is a generated test track
[00:05.00]With time-synced lyrics
[00:10.00]So the lyrics view has something to show
[00:15.00]Line four arrives at fifteen seconds
[00:20.00]And the song is almost over
[00:25.00]Goodbye
"""


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path)
    parser.add_argument("--seconds", type=int, default=30)
    args = parser.parse_args()

    count = 0
    for album_index, (artist, album, year, genre, ext, (c0, c1), titles) in enumerate(ALBUMS):
        folder = args.out / artist / f"{album} ({year})"
        folder.mkdir(parents=True, exist_ok=True)
        cover = folder / "cover.jpg"
        if not cover.exists():
            run(["ffmpeg", "-y", "-f", "lavfi", "-i",
                 f"gradients=s=600x600:c0={c0}:c1={c1}:x0=0:y0=0:x1=600:y1=600",
                 "-frames:v", "1", str(cover)])
        for index, title in enumerate(titles, start=1):
            path = folder / f"{index:02d} - {title}.{ext}"
            count += 1
            if path.exists():
                continue
            # Different pitch per track, different loudness per album so
            # loudness leveling has work to do.
            freq = 110 * (2 ** (((album_index * 5 + index * 3) % 24) / 12))
            volume = 0.35 + 0.1 * (album_index % 5)
            graph = VOICES[genre].format(f=f"{freq:.2f}", d=args.seconds)
            graph += f",volume={volume:.2f},afade=t=in:d=1,afade=t=out:st={args.seconds - 2}:d=2[out]"
            track_artist = artist if artist != "Various Artists" else ["Neon Circuit", "Aurora Drift"][index % 2]
            run(
                ["ffmpeg", "-y", "-filter_complex", graph, "-map", "[out]", "-ac", "2", "-ar", "44100",
                 *CODECS[ext],
                 "-metadata", f"title={title}",
                 "-metadata", f"artist={track_artist}",
                 "-metadata", f"album_artist={artist}",
                 "-metadata", f"album={album}",
                 "-metadata", f"genre={genre}",
                 "-metadata", f"date={year}",
                 "-metadata", f"track={index}/{len(titles)}",
                 str(path)])
            if index == 1:
                path.with_suffix(".lrc").write_text(LRC)
    print(f"{count} tracks in {len(ALBUMS)} albums under {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
