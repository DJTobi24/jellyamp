"""Cosine-distance similarity over track embeddings.

Track similarity is direct kNN; artist/album similarity uses the centroid of
their tracks' embeddings. Every function accepts either a plain list of
`TrackRecord`s (wrapped on the fly) or a prebuilt `LibraryIndex`.
"""

from collections.abc import Sequence

import numpy as np

from jellyamp_server.sonic.index import LibraryIndex
from jellyamp_server.store import TrackRecord

Library = LibraryIndex | Sequence[TrackRecord]


def cosine_distance(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0:
        return 1.0
    return float(1.0 - np.dot(a, b) / denom)


def similar_tracks(
    seed: TrackRecord,
    candidates: Library,
    limit: int,
    exclude_same_album: bool = False,
) -> list[tuple[str, float]]:
    index = LibraryIndex.wrap(candidates)
    exclude = index.mask([seed.item_id], seed.album_id if exclude_same_album else None)
    return [
        (track.item_id, distance)
        for track, distance in index.nearest(seed.embedding, limit, exclude)
    ]


def similar_groups(
    seed_group_id: str,
    tracks: Library,
    key: str,
    limit: int,
) -> list[tuple[str, float]]:
    """Similar artists (key='artist_id') or albums (key='album_id') by centroid."""
    ids, centroids = LibraryIndex.wrap(tracks).group_centroids(key)
    if seed_group_id not in ids:
        return []
    seed_row = ids.index(seed_group_id)
    distances = np.clip(1.0 - centroids @ centroids[seed_row], 0.0, 2.0)
    order = [row for row in np.lexsort((np.arange(len(ids)), distances)) if row != seed_row]
    return [(ids[row], float(distances[row])) for row in order[:limit]]
