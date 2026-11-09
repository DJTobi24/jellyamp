"""SQLite store for track embeddings, loudness, and the minimal metadata the
sonic features need (titles/artist names for mix descriptions and Sonic Sage,
genres/years for stations).

Everything in here is derived from Jellyfin and can be rebuilt by a scan, so
there are no migrations: a database written by another schema version is
simply reset (see `SCHEMA_VERSION`).

Embeddings are float32 BLOBs. Queries never touch them directly — the store
hands out a cached `LibraryIndex` (one numpy matrix) that is rebuilt lazily
after writes. Brute-force cosine over a few hundred thousand tracks is a few
milliseconds; a sqlite-vec index is a drop-in upgrade later.
"""

import json
import logging
import sqlite3
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from jellyamp_server.sonic.index import LibraryIndex

logger = logging.getLogger(__name__)

# Bump on any incompatible change to SCHEMA; old databases are then reset.
SCHEMA_VERSION = 2

SCHEMA = """
CREATE TABLE IF NOT EXISTS tracks (
    item_id TEXT PRIMARY KEY,
    extractor TEXT NOT NULL DEFAULT '',
    artist_id TEXT,
    album_id TEXT,
    embedding BLOB NOT NULL,
    integrated_lufs REAL,
    true_peak REAL,
    genres TEXT NOT NULL DEFAULT '[]',
    year INTEGER,
    title TEXT,
    artist_name TEXT,
    album_name TEXT,
    analyzed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_tracks_extractor ON tracks(extractor);
CREATE TABLE IF NOT EXISTS failures (
    item_id TEXT PRIMARY KEY,
    extractor TEXT NOT NULL,
    attempts INTEGER NOT NULL,
    last_error TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS mixes_cache (
    user_id TEXT NOT NULL,
    week TEXT NOT NULL,
    library_size INTEGER NOT NULL,
    payload TEXT NOT NULL,
    PRIMARY KEY (user_id, week)
);
"""


@dataclass
class TrackRecord:
    item_id: str
    embedding: np.ndarray
    artist_id: str | None = None
    album_id: str | None = None
    integrated_lufs: float | None = None
    true_peak: float | None = None
    genres: list[str] = field(default_factory=list)
    year: int | None = None
    title: str | None = None
    artist_name: str | None = None
    album_name: str | None = None
    # "<name>/<version>" of the extractor that produced `embedding`.
    extractor: str = ""


class EmbeddingStore:
    """All access is serialized by a lock; SQLite work here is microseconds."""

    _COLUMNS = (
        "item_id, artist_id, album_id, embedding, integrated_lufs, true_peak, genres, year, "
        "title, artist_name, album_name, extractor"
    )

    def __init__(
        self,
        path: str | Path,
        *,
        active_extractor: str | None = None,
        standardize: bool = False,
        weights: np.ndarray | None = None,
    ):
        """`active_extractor`: only tracks analyzed by it are served (None = all)."""
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(path), check_same_thread=False)
        self._active = active_extractor
        self._standardize = standardize
        self._weights = weights
        self._index: LibraryIndex | None = None
        self._init_schema()

    def _init_schema(self) -> None:
        with self._lock:
            version = self._conn.execute("PRAGMA user_version").fetchone()[0]
            has_tables = self._conn.execute(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'"
            ).fetchone()[0]
            if has_tables and version != SCHEMA_VERSION:
                logger.warning(
                    "database schema v%s != v%s: resetting (analysis will re-run)",
                    version,
                    SCHEMA_VERSION,
                )
                for (name,) in self._conn.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                ).fetchall():
                    self._conn.execute(f'DROP TABLE IF EXISTS "{name}"')
            self._conn.executescript(SCHEMA)
            self._conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            self._conn.commit()

    # ------------------------------------------------------------- tracks

    def _filter(self) -> tuple[str, tuple]:
        if self._active is None:
            return "", ()
        return " WHERE extractor = ?", (self._active,)

    def upsert(self, record: TrackRecord) -> None:
        with self._lock:
            self._conn.execute(
                """
                INSERT OR REPLACE INTO tracks
                    (item_id, extractor, artist_id, album_id, embedding, integrated_lufs,
                     true_peak, genres, year, title, artist_name, album_name)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    record.item_id,
                    record.extractor or self._active or "",
                    record.artist_id,
                    record.album_id,
                    np.asarray(record.embedding, dtype=np.float32).tobytes(),
                    record.integrated_lufs,
                    record.true_peak,
                    json.dumps(record.genres),
                    record.year,
                    record.title,
                    record.artist_name,
                    record.album_name,
                ),
            )
            self._conn.execute("DELETE FROM failures WHERE item_id = ?", (record.item_id,))
            self._conn.commit()
            self._index = None

    def update_metadata(self, records: list[TrackRecord]) -> int:
        """Refreshes tags of already-analyzed tracks (retagged in Jellyfin)."""
        changed = 0
        with self._lock:
            for record in records:
                cursor = self._conn.execute(
                    """
                    UPDATE tracks SET artist_id = ?, album_id = ?, genres = ?, year = ?,
                        title = ?, artist_name = ?, album_name = ?
                    WHERE item_id = ? AND (
                        artist_id IS NOT ? OR album_id IS NOT ? OR genres IS NOT ?
                        OR year IS NOT ? OR title IS NOT ? OR artist_name IS NOT ?
                        OR album_name IS NOT ?)
                    """,
                    (
                        record.artist_id, record.album_id, json.dumps(record.genres),
                        record.year, record.title, record.artist_name, record.album_name,
                        record.item_id,
                        record.artist_id, record.album_id, json.dumps(record.genres),
                        record.year, record.title, record.artist_name, record.album_name,
                    ),
                )  # fmt: skip
                changed += cursor.rowcount
            if changed:
                self._conn.commit()
                self._index = None
        return changed

    def delete(self, item_ids: list[str]) -> int:
        if not item_ids:
            return 0
        with self._lock:
            removed = 0
            for item_id in item_ids:
                removed += self._conn.execute(
                    "DELETE FROM tracks WHERE item_id = ?", (item_id,)
                ).rowcount
                self._conn.execute("DELETE FROM failures WHERE item_id = ?", (item_id,))
            self._conn.commit()
            self._index = None
            return removed

    def get(self, item_id: str) -> TrackRecord | None:
        """The raw stored record (any extractor). Queries should use `index()`."""
        with self._lock:
            row = self._conn.execute(
                f"SELECT {self._COLUMNS} FROM tracks WHERE item_id = ?",  # noqa: S608
                (item_id,),
            ).fetchone()
        return None if row is None else self._record(row)

    def all_tracks(self) -> list[TrackRecord]:
        where, params = self._filter()
        with self._lock:
            rows = self._conn.execute(
                f"SELECT {self._COLUMNS} FROM tracks{where} ORDER BY item_id",  # noqa: S608
                params,
            ).fetchall()
        return [self._record(row) for row in rows]

    def count(self) -> int:
        where, params = self._filter()
        with self._lock:
            return self._conn.execute(f"SELECT COUNT(*) FROM tracks{where}", params).fetchone()[0]  # noqa: S608

    def loudness_count(self) -> int:
        where, params = self._filter()
        clause = (where + " AND " if where else " WHERE ") + "integrated_lufs IS NOT NULL"
        with self._lock:
            return self._conn.execute(f"SELECT COUNT(*) FROM tracks{clause}", params).fetchone()[0]  # noqa: S608

    def known_ids(self) -> set[str]:
        """IDs analyzed by the active extractor."""
        where, params = self._filter()
        with self._lock:
            return {
                row[0]
                for row in self._conn.execute(f"SELECT item_id FROM tracks{where}", params)  # noqa: S608
            }

    def stored_ids(self) -> set[str]:
        """Every stored ID, including leftovers from other extractors."""
        with self._lock:
            return {row[0] for row in self._conn.execute("SELECT item_id FROM tracks")}

    def index(self) -> "LibraryIndex":
        """Cached similarity index over the active extractor's tracks."""
        from jellyamp_server.sonic.index import LibraryIndex

        with self._lock:
            if self._index is None:
                self._index = LibraryIndex(
                    self.all_tracks(), standardize=self._standardize, weights=self._weights
                )
            return self._index

    @staticmethod
    def _record(row: tuple) -> TrackRecord:
        return TrackRecord(
            item_id=row[0],
            artist_id=row[1],
            album_id=row[2],
            embedding=np.frombuffer(row[3], dtype=np.float32),
            integrated_lufs=row[4],
            true_peak=row[5],
            genres=json.loads(row[6]) if row[6] else [],
            year=row[7],
            title=row[8],
            artist_name=row[9],
            album_name=row[10],
            extractor=row[11],
        )

    # ----------------------------------------------------------- failures

    def record_failure(self, item_id: str, error: str) -> int:
        """Counts a failed analysis attempt; returns the attempt number."""
        extractor = self._active or ""
        with self._lock:
            self._conn.execute(
                """
                INSERT INTO failures (item_id, extractor, attempts, last_error)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                    attempts = CASE WHEN extractor = excluded.extractor
                                    THEN attempts + 1 ELSE 1 END,
                    extractor = excluded.extractor,
                    last_error = excluded.last_error,
                    updated_at = datetime('now')
                """,
                (item_id, extractor, error[:500]),
            )
            self._conn.commit()
            return self._conn.execute(
                "SELECT attempts FROM failures WHERE item_id = ?", (item_id,)
            ).fetchone()[0]

    def exhausted_ids(self, max_attempts: int) -> set[str]:
        """Tracks the active extractor has given up on."""
        with self._lock:
            return {
                row[0]
                for row in self._conn.execute(
                    "SELECT item_id FROM failures WHERE extractor = ? AND attempts >= ?",
                    (self._active or "", max_attempts),
                )
            }

    def failures(self, limit: int = 50) -> list[dict]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT item_id, attempts, last_error FROM failures WHERE extractor = ? "
                "ORDER BY updated_at DESC LIMIT ?",
                (self._active or "", limit),
            ).fetchall()
        return [{"itemId": r[0], "attempts": r[1], "error": r[2]} for r in rows]

    def clear_failures(self) -> None:
        with self._lock:
            self._conn.execute("DELETE FROM failures")
            self._conn.commit()

    # --------------------------------------------------------------- meta

    def get_meta(self, key: str) -> str | None:
        with self._lock:
            row = self._conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return None if row is None else row[0]

    def set_meta(self, key: str, value: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO meta (key, value) VALUES (?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )
            self._conn.commit()

    # -------------------------------------------------------------- mixes

    def cached_mixes(self, user_id: str, week: str) -> tuple[int, list[dict]] | None:
        """(library size when built, mixes) for this user and ISO week."""
        with self._lock:
            row = self._conn.execute(
                "SELECT library_size, payload FROM mixes_cache WHERE user_id = ? AND week = ?",
                (user_id, week),
            ).fetchone()
        return None if row is None else (row[0], json.loads(row[1]))

    def cache_mixes(self, user_id: str, week: str, library_size: int, mixes: list[dict]) -> None:
        with self._lock:
            # Older weeks are never read again.
            self._conn.execute("DELETE FROM mixes_cache WHERE week != ?", (week,))
            self._conn.execute(
                "INSERT OR REPLACE INTO mixes_cache (user_id, week, library_size, payload) "
                "VALUES (?, ?, ?, ?)",
                (user_id, week, library_size, json.dumps(mixes)),
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()
