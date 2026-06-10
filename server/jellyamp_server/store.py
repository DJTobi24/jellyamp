"""SQLite store for track embeddings and loudness.

Embeddings are float32 BLOBs; similarity queries load them into numpy.
Libraries up to a few hundred thousand tracks are fine with brute-force
cosine distance; a sqlite-vec index is a drop-in upgrade later.
"""

import sqlite3
from dataclasses import dataclass
from pathlib import Path

import numpy as np

SCHEMA = """
CREATE TABLE IF NOT EXISTS tracks (
    item_id TEXT PRIMARY KEY,
    artist_id TEXT,
    album_id TEXT,
    embedding BLOB NOT NULL,
    integrated_lufs REAL,
    true_peak REAL,
    analyzed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_tracks_artist ON tracks(artist_id);
CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album_id);
"""


@dataclass
class TrackRecord:
    item_id: str
    embedding: np.ndarray
    artist_id: str | None = None
    album_id: str | None = None
    integrated_lufs: float | None = None
    true_peak: float | None = None


class EmbeddingStore:
    def __init__(self, path: str | Path):
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(path), check_same_thread=False)
        self._conn.executescript(SCHEMA)

    def upsert(self, record: TrackRecord) -> None:
        self._conn.execute(
            """
            INSERT INTO tracks (item_id, artist_id, album_id, embedding, integrated_lufs, true_peak)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
                artist_id = excluded.artist_id,
                album_id = excluded.album_id,
                embedding = excluded.embedding,
                integrated_lufs = excluded.integrated_lufs,
                true_peak = excluded.true_peak,
                analyzed_at = datetime('now')
            """,
            (
                record.item_id,
                record.artist_id,
                record.album_id,
                record.embedding.astype(np.float32).tobytes(),
                record.integrated_lufs,
                record.true_peak,
            ),
        )
        self._conn.commit()

    def get(self, item_id: str) -> TrackRecord | None:
        row = self._conn.execute(
            "SELECT item_id, artist_id, album_id, embedding, integrated_lufs, true_peak"
            " FROM tracks WHERE item_id = ?",
            (item_id,),
        ).fetchone()
        if row is None:
            return None
        return self._record(row)

    def all_tracks(self) -> list[TrackRecord]:
        rows = self._conn.execute(
            "SELECT item_id, artist_id, album_id, embedding, integrated_lufs, true_peak FROM tracks"
        ).fetchall()
        return [self._record(row) for row in rows]

    def count(self) -> int:
        return self._conn.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]

    def known_ids(self) -> set[str]:
        return {row[0] for row in self._conn.execute("SELECT item_id FROM tracks")}

    @staticmethod
    def _record(row: tuple) -> TrackRecord:
        return TrackRecord(
            item_id=row[0],
            artist_id=row[1],
            album_id=row[2],
            embedding=np.frombuffer(row[3], dtype=np.float32),
            integrated_lufs=row[4],
            true_peak=row[5],
        )
