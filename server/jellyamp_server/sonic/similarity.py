"""Cosine-distance similarity over track embeddings.

Track similarity is direct kNN; artist/album similarity uses the centroid of
their tracks' embeddings.
"""

from collections import defaultdict

import numpy as np

from jellyamp_server.store import TrackRecord


def cosine_distance(a: np.ndarray, b: np.ndarray) -> float:
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0:
        return 1.0
    return float(1.0 - np.dot(a, b) / denom)


def _distance_matrix(query: np.ndarray, embeddings: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(embeddings, axis=1) * np.linalg.norm(query)
    norms[norms == 0] = np.inf
    return 1.0 - (embeddings @ query) / norms


def similar_tracks(
    seed: TrackRecord,
    candidates: list[TrackRecord],
    limit: int,
    exclude_same_album: bool = False,
) -> list[tuple[str, float]]:
    pool = [
        track
        for track in candidates
        if track.item_id != seed.item_id
        and not (exclude_same_album and track.album_id and track.album_id == seed.album_id)
    ]
    if not pool:
        return []
    embeddings = np.stack([track.embedding for track in pool])
    distances = _distance_matrix(seed.embedding, embeddings)
    order = np.argsort(distances)[:limit]
    return [(pool[i].item_id, float(distances[i])) for i in order]


def _centroids(tracks: list[TrackRecord], key: str) -> dict[str, np.ndarray]:
    groups: dict[str, list[np.ndarray]] = defaultdict(list)
    for track in tracks:
        group_id = getattr(track, key)
        if group_id:
            groups[group_id].append(track.embedding)
    return {group_id: np.mean(np.stack(members), axis=0) for group_id, members in groups.items()}


def similar_groups(
    seed_group_id: str,
    tracks: list[TrackRecord],
    key: str,
    limit: int,
) -> list[tuple[str, float]]:
    """Similar artists (key='artist_id') or albums (key='album_id') by centroid."""
    centroids = _centroids(tracks, key)
    seed = centroids.get(seed_group_id)
    if seed is None:
        return []
    others = [
        (group_id, centroid)
        for group_id, centroid in centroids.items()
        if group_id != seed_group_id
    ]
    ranked = sorted(
        ((group_id, cosine_distance(seed, centroid)) for group_id, centroid in others),
        key=lambda pair: pair[1],
    )
    return ranked[:limit]
