"""Weekly auto-mixes ("Mixes for You") and station generation.

Mixes: k-means-style clustering of the user's recently played tracks; each
cluster seeds a mix that is filled with the sonically nearest library tracks.
Kept dependency-light (numpy only) and deterministic per ISO week so mix IDs
are stable for seven days.
"""

import datetime as dt
import random

import numpy as np

from jellyamp_server.sonic.similarity import similar_tracks
from jellyamp_server.store import TrackRecord


def week_key(today: dt.date | None = None) -> str:
    date = today or dt.date.today()
    iso = date.isocalendar()
    return f"{iso.year}-w{iso.week:02d}"


def _kmeans(embeddings: np.ndarray, k: int, iterations: int = 10, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    centroids = embeddings[rng.choice(len(embeddings), size=k, replace=False)]
    for _ in range(iterations):
        distances = np.linalg.norm(embeddings[:, None, :] - centroids[None, :, :], axis=2)
        assignment = distances.argmin(axis=1)
        for cluster in range(k):
            members = embeddings[assignment == cluster]
            if len(members):
                centroids[cluster] = members.mean(axis=0)
    return assignment


def build_mixes(
    recent: list[TrackRecord],
    library: list[TrackRecord],
    max_mixes: int = 4,
    tracks_per_mix: int = 30,
    today: dt.date | None = None,
) -> list[dict]:
    """Returns mix dicts shaped like docs/SONIC-API.md `GET /mixes`."""
    if not recent:
        return []
    key = week_key(today)
    k = min(max_mixes, len(recent))
    embeddings = np.stack([track.embedding for track in recent])
    # Deterministic per week: same library + week → same mixes.
    assignment = _kmeans(embeddings, k, seed=int(key.split("-w")[1]))

    mixes: list[dict] = []
    for cluster in range(k):
        seeds = [track for track, label in zip(recent, assignment, strict=True) if label == cluster]
        if not seeds:
            continue
        centroid_seed = seeds[0]
        seed_ids = [track.item_id for track in seeds[:5]]
        fill = similar_tracks(centroid_seed, library, limit=tracks_per_mix)
        item_ids = [item_id for item_id, _ in fill if item_id not in seed_ids]
        if not item_ids:
            continue
        mixes.append(
            {
                "id": f"mix-{key}-{len(mixes) + 1}",
                "title": f"Mix #{len(mixes) + 1}",
                "description": "Based on your recent listening",
                "seedItemIds": seed_ids,
                "itemIds": item_ids[:tracks_per_mix],
            }
        )
    return mixes


def build_station(
    seed_tracks: list[TrackRecord],
    library: list[TrackRecord],
    count: int,
    shuffle_seed: int | None = None,
) -> list[str]:
    """Fills a station around seed tracks: nearest neighbours, shuffled."""
    collected: dict[str, float] = {}
    per_seed = max(count // max(len(seed_tracks), 1), 1)
    for seed in seed_tracks:
        for item_id, distance in similar_tracks(seed, library, limit=per_seed * 2):
            if item_id not in collected or distance < collected[item_id]:
                collected[item_id] = distance
    ranked = sorted(collected.items(), key=lambda pair: pair[1])[: count * 2]
    rng = random.Random(shuffle_seed)
    rng.shuffle(ranked)
    return [item_id for item_id, _ in ranked[:count]]
