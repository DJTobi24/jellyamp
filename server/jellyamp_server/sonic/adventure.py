"""Sonic Adventure: a listening path between two tracks.

Linearly interpolates between the two seed embeddings and picks the nearest
unused track for each waypoint, deduplicating artists inside a sliding window
so the path doesn't collapse onto one artist's catalogue.
"""


from jellyamp_server.sonic.similarity import cosine_distance
from jellyamp_server.store import TrackRecord

ARTIST_DEDUPE_WINDOW = 3


def adventure_path(
    start: TrackRecord,
    end: TrackRecord,
    candidates: list[TrackRecord],
    steps: int,
) -> list[tuple[str, int, float]]:
    """Returns (item_id, position, distance-to-waypoint); endpoints included."""
    if steps < 1:
        return [(start.item_id, 0, 0.0), (end.item_id, 1, 0.0)]

    used_ids = {start.item_id, end.item_id}
    recent_artists: list[str | None] = [start.artist_id]
    path: list[tuple[str, int, float]] = [(start.item_id, 0, 0.0)]

    for step in range(1, steps + 1):
        t = step / (steps + 1)
        waypoint = (1.0 - t) * start.embedding + t * end.embedding
        best: tuple[str, float, TrackRecord] | None = None
        for track in candidates:
            if track.item_id in used_ids:
                continue
            if track.artist_id and track.artist_id in recent_artists[-ARTIST_DEDUPE_WINDOW:]:
                continue
            distance = cosine_distance(waypoint, track.embedding)
            if best is None or distance < best[1]:
                best = (track.item_id, distance, track)
        if best is None:
            continue
        used_ids.add(best[0])
        recent_artists.append(best[2].artist_id)
        path.append((best[0], step, best[1]))

    path.append((end.item_id, len(path), 0.0))
    # Re-number positions densely (skipped waypoints must not leave holes).
    return [(item_id, index, distance) for index, (item_id, _, distance) in enumerate(path)]
