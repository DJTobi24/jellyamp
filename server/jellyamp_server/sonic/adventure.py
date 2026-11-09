"""Sonic Adventure: a listening path between two tracks.

Linearly interpolates between the two seed embeddings and picks the nearest
unused track for each waypoint, deduplicating artists inside a sliding window
so the path doesn't collapse onto one artist's catalogue.
"""

import numpy as np

from jellyamp_server.sonic.index import LibraryIndex
from jellyamp_server.sonic.similarity import Library
from jellyamp_server.store import TrackRecord

ARTIST_DEDUPE_WINDOW = 3


def adventure_path(
    start: TrackRecord,
    end: TrackRecord,
    candidates: Library,
    steps: int,
) -> list[tuple[str, int, float]]:
    """Returns (item_id, position, distance-to-waypoint); endpoints included."""
    if steps < 1:
        return [(start.item_id, 0, 0.0), (end.item_id, 1, 0.0)]

    index = LibraryIndex.wrap(candidates)
    used = index.mask([start.item_id, end.item_id])
    artists = np.array([track.artist_id or "" for track in index.records], dtype=object)
    recent_artists: list[str | None] = [start.artist_id]
    path: list[tuple[str, int, float]] = [(start.item_id, 0, 0.0)]

    for step in range(1, steps + 1):
        t = step / (steps + 1)
        waypoint = (1.0 - t) * start.embedding + t * end.embedding
        blocked = used.copy()
        for artist in recent_artists[-ARTIST_DEDUPE_WINDOW:]:
            if artist:
                blocked |= artists == artist
        best = index.nearest(waypoint, 1, blocked)
        if not best:
            continue
        track, distance = best[0]
        used[index.row(track.item_id)] = True
        recent_artists.append(track.artist_id)
        path.append((track.item_id, step, distance))

    path.append((end.item_id, len(path), 0.0))
    # Re-number positions densely (skipped waypoints must not leave holes).
    return [(item_id, position, distance) for position, (item_id, _, distance) in enumerate(path)]
