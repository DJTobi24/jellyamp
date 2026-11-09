"""In-memory similarity index: one unit-normalized matrix for the library.

Built once per store generation (the store invalidates it on writes), so a
similarity query is a single matrix–vector product instead of re-reading
every embedding from SQLite.

For hand-crafted feature vectors (`standardize=True`, the DSP backend) the
matrix is z-scored per dimension across the library and weighted before
normalization: dimensions measured in different units become comparable and
"distance" means "unusual relative to *this* library". Learned embeddings
(MusiCNN) are used as they are.
"""

from collections.abc import Sequence
from dataclasses import replace

import numpy as np

from jellyamp_server.store import TrackRecord

# Below this many tracks per-dimension statistics are noise; use raw vectors.
MIN_TRACKS_TO_STANDARDIZE = 5
_Z_CLIP = 4.0


def _unit_rows(matrix: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return matrix / norms


class LibraryIndex:
    """Immutable snapshot of analyzed tracks in similarity space.

    `records[i].embedding` is row `i` of `matrix` (projected, unit length), so
    code that works on `TrackRecord`s and code that works on the matrix agree.
    """

    def __init__(
        self,
        records: Sequence[TrackRecord],
        *,
        standardize: bool = False,
        weights: np.ndarray | None = None,
    ):
        records = _same_dimension(records)
        if records:
            raw = np.stack([record.embedding for record in records]).astype(np.float32)
            if standardize and len(records) >= MIN_TRACKS_TO_STANDARDIZE:
                std = raw.std(axis=0)
                # A dimension that never varies carries no information here.
                usable = std > 1e-9
                raw = np.where(usable, (raw - raw.mean(axis=0)) / np.where(usable, std, 1.0), 0.0)
                raw = np.clip(raw, -_Z_CLIP, _Z_CLIP)
                if weights is not None and len(weights) == raw.shape[1]:
                    raw = raw * weights
            self.matrix = _unit_rows(raw.astype(np.float32))
        else:
            self.matrix = np.zeros((0, 0), dtype=np.float32)
        self.records: list[TrackRecord] = [
            replace(record, embedding=self.matrix[i]) for i, record in enumerate(records)
        ]
        self._rows = {record.item_id: i for i, record in enumerate(self.records)}
        self._group_cache: dict[str, tuple[list[str], np.ndarray]] = {}

    @classmethod
    def wrap(cls, library: "LibraryIndex | Sequence[TrackRecord]") -> "LibraryIndex":
        return library if isinstance(library, LibraryIndex) else cls(library)

    def __len__(self) -> int:
        return len(self.records)

    def get(self, item_id: str) -> TrackRecord | None:
        row = self._rows.get(item_id)
        return None if row is None else self.records[row]

    def row(self, item_id: str) -> int | None:
        return self._rows.get(item_id)

    def distances(self, query: np.ndarray) -> np.ndarray:
        """Cosine distance from `query` to every track (one matvec)."""
        if len(self.records) == 0:
            return np.zeros(0, dtype=np.float32)
        norm = float(np.linalg.norm(query))
        if norm == 0 or len(query) != self.matrix.shape[1]:
            return np.ones(len(self.records), dtype=np.float32)
        distances = 1.0 - self.matrix @ (np.asarray(query, dtype=np.float32) / norm)
        # Zero rows (degenerate embeddings) are "unrelated", not "identical-ish".
        distances[~self.matrix.any(axis=1)] = 1.0
        return np.clip(distances, 0.0, 2.0)

    def nearest(
        self, query: np.ndarray, limit: int, exclude: np.ndarray | None = None
    ) -> list[tuple[TrackRecord, float]]:
        """The `limit` closest tracks, ascending; `exclude` is a boolean row mask."""
        distances = self.distances(query)
        if exclude is not None:
            distances = np.where(exclude, np.inf, distances)
        candidates = np.flatnonzero(np.isfinite(distances))
        if len(candidates) == 0 or limit <= 0:
            return []
        if len(candidates) > limit:
            part = np.argpartition(distances[candidates], limit - 1)[:limit]
            candidates = candidates[part]
        # Stable tie-break on row order keeps results deterministic.
        order = candidates[np.lexsort((candidates, distances[candidates]))]
        return [(self.records[i], float(distances[i])) for i in order]

    def mask(self, item_ids: Sequence[str] = (), album_id: str | None = None) -> np.ndarray:
        mask = np.zeros(len(self.records), dtype=bool)
        for item_id in item_ids:
            row = self._rows.get(item_id)
            if row is not None:
                mask[row] = True
        if album_id:
            mask |= np.fromiter(
                (record.album_id == album_id for record in self.records), bool, len(self.records)
            )
        return mask

    def subset(self, records: Sequence[TrackRecord]) -> "LibraryIndex":
        """A view over some of this index's tracks, keeping their projection."""
        view = LibraryIndex.__new__(LibraryIndex)
        rows = [self._rows[record.item_id] for record in records if record.item_id in self._rows]
        view.matrix = (
            self.matrix[rows] if rows else np.zeros((0, self.matrix.shape[1]), np.float32)
        )
        view.records = [self.records[row] for row in rows]
        view._rows = {record.item_id: i for i, record in enumerate(view.records)}
        view._group_cache = {}
        return view

    def centroid(self, records: Sequence[TrackRecord]) -> np.ndarray:
        return np.mean(np.stack([record.embedding for record in records]), axis=0)

    def group_centroids(self, key: str) -> tuple[list[str], np.ndarray]:
        """(group ids, unit centroid matrix) for key 'artist_id' or 'album_id'."""
        if key not in self._group_cache:
            members: dict[str, list[int]] = {}
            for row, record in enumerate(self.records):
                group_id = getattr(record, key)
                if group_id:
                    members.setdefault(group_id, []).append(row)
            ids = list(members)
            if ids:
                centroids = np.stack([self.matrix[rows].mean(axis=0) for rows in members.values()])
                centroids = _unit_rows(centroids)
            else:
                centroids = np.zeros((0, 0), dtype=np.float32)
            self._group_cache[key] = (ids, centroids)
        return self._group_cache[key]


def _same_dimension(records: Sequence[TrackRecord]) -> list[TrackRecord]:
    """Drops stragglers whose embedding size differs from the majority."""
    if not records:
        return []
    sizes: dict[int, int] = {}
    for record in records:
        sizes[len(record.embedding)] = sizes.get(len(record.embedding), 0) + 1
    if len(sizes) == 1:
        return list(records)
    majority = max(sizes, key=lambda size: sizes[size])
    return [record for record in records if len(record.embedding) == majority]
