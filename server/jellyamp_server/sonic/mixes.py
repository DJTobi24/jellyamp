"""Weekly auto-mixes ("Mixes for You") and station generation.

Mixes: k-means-style clustering of the user's recently played tracks; each
cluster seeds a mix that is filled with the sonically nearest library tracks.
Kept dependency-light (numpy only) and deterministic per ISO week so mix IDs
are stable for seven days.
"""

import datetime as dt
import random
from collections import Counter

import numpy as np

from jellyamp_server.sonic.index import LibraryIndex
from jellyamp_server.sonic.similarity import Library
from jellyamp_server.store import TrackRecord

# No more than this many tracks by one artist in a mix (when there is choice).
MAX_TRACKS_PER_ARTIST = 4


def week_key(today: dt.date | None = None) -> str:
    date = today or dt.date.today()
    iso = date.isocalendar()
    return f"{iso.year}-w{iso.week:02d}"


def _kmeans(embeddings: np.ndarray, k: int, iterations: int = 10, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    centroids = embeddings[rng.choice(len(embeddings), size=k, replace=False)].copy()
    assignment = np.zeros(len(embeddings), dtype=int)
    for _ in range(iterations):
        distances = np.linalg.norm(embeddings[:, None, :] - centroids[None, :, :], axis=2)
        assignment = distances.argmin(axis=1)
        for cluster in range(k):
            members = embeddings[assignment == cluster]
            if len(members):
                centroids[cluster] = members.mean(axis=0)
    return assignment


def _unique_names(names: list[str | None]) -> list[str]:
    seen: dict[str, None] = {}
    for name in names:
        if name:
            seen.setdefault(name)
    return list(seen)


def describe_seeds(seeds: list[TrackRecord], from_history: bool = True) -> str:
    """"Based on Slowdive, Ride and 4 more" from the seeds' artist names."""
    artists = _unique_names([track.artist_name for track in seeds])
    if not artists:
        return "Based on your recent listening" if from_history else "Picked from your library"
    lead = "Based on" if from_history else "Around"
    if len(artists) == 1:
        return f"{lead} {artists[0]}"
    if len(artists) == 2:
        return f"{lead} {artists[0]} and {artists[1]}"
    return f"{lead} {artists[0]}, {artists[1]} and {len(artists) - 2} more"


def title_for(seeds: list[TrackRecord], fallback: str) -> str:
    """A genre title when the seeds agree on one, else the lead artist."""
    genres = Counter(genre for track in seeds for genre in track.genres[:1])
    if genres:
        genre, votes = genres.most_common(1)[0]
        if votes * 2 >= len(seeds):
            return f"{genre} Mix"
    artists = Counter(track.artist_name for track in seeds if track.artist_name)
    if artists:
        return f"{artists.most_common(1)[0][0]} Mix"
    return fallback


def _cap_per_artist(
    ranked: list[tuple[TrackRecord, float]], limit: int, per_artist: int
) -> list[TrackRecord]:
    """First `limit` tracks with at most `per_artist` each; relaxes if short."""
    counts: Counter[str] = Counter()
    picked: list[TrackRecord] = []
    skipped: list[TrackRecord] = []
    for track, _ in ranked:
        if track.artist_id and counts[track.artist_id] >= per_artist:
            skipped.append(track)
            continue
        if track.artist_id:
            counts[track.artist_id] += 1
        picked.append(track)
        if len(picked) == limit:
            return picked
    return (picked + skipped)[:limit]


def build_mixes(
    recent: list[TrackRecord],
    library: Library,
    max_mixes: int = 4,
    tracks_per_mix: int = 30,
    today: dt.date | None = None,
    from_history: bool = True,
) -> list[dict]:
    """Returns mix dicts shaped like docs/SONIC-API.md `GET /mixes`."""
    if not recent:
        return []
    index = LibraryIndex.wrap(library)
    key = week_key(today)
    k = min(max_mixes, len(recent))
    embeddings = np.stack([track.embedding for track in recent])
    # Deterministic per week: same history + library + week → same mixes.
    assignment = _kmeans(embeddings, k, seed=int(key.split("-w")[1]))

    mixes: list[dict] = []
    titles: Counter[str] = Counter()
    for cluster in range(k):
        seeds = [track for track, label in zip(recent, assignment, strict=True) if label == cluster]
        if not seeds:
            continue
        centroid = np.mean(np.stack([track.embedding for track in seeds]), axis=0)
        # Seeds closest to the cluster centre represent it best.
        seeds.sort(key=lambda track: float(np.linalg.norm(track.embedding - centroid)))
        seed_ids = [track.item_id for track in seeds[:5]]
        ranked = index.nearest(centroid, tracks_per_mix * 3, index.mask(seed_ids))
        picked = _cap_per_artist(ranked, tracks_per_mix, MAX_TRACKS_PER_ARTIST)
        if not picked:
            continue
        number = len(mixes) + 1
        title = title_for(seeds[:5], fallback=f"Mix #{number}")
        titles[title] += 1
        if titles[title] > 1:
            title = f"{title} {titles[title]}"
        mixes.append(
            {
                "id": f"mix-{key}-{number}",
                "title": title,
                "description": describe_seeds(seeds[:5], from_history),
                "seedItemIds": seed_ids,
                "itemIds": [track.item_id for track in picked],
            }
        )
    return mixes


def library_seeds(library: Library, today: dt.date | None = None, count: int = 40) -> list:
    """Week-stable sample of the library, for users without listening history."""
    index = LibraryIndex.wrap(library)
    records = sorted(index.records, key=lambda track: track.item_id)
    rng = random.Random(week_key(today))
    return rng.sample(records, min(count, len(records)))


def station_subset(
    library: Library,
    station_type: str,
    seed: str,
) -> list[TrackRecord]:
    """Tracks eligible for a genre/style/decade station.

    Genre and style both match against track genre tags (Jellyfin does not
    distinguish them); decade seeds look like "1990s".
    """
    records = LibraryIndex.wrap(library).records
    if station_type in ("genre", "style"):
        wanted = seed.strip().lower()
        return [t for t in records if any(g.lower() == wanted for g in t.genres)]
    if station_type == "decade":
        try:
            start = int(seed.strip()[:4])
        except ValueError:
            return []
        return [t for t in records if t.year is not None and start <= t.year <= start + 9]
    return []


def build_station(
    seed_tracks: list[TrackRecord],
    library: Library,
    count: int,
    shuffle_seed: int | None = None,
) -> list[str]:
    """Fills a station around seed tracks: nearest neighbours, shuffled."""
    index = LibraryIndex.wrap(library)
    collected: dict[str, float] = {}
    per_seed = max(count // max(len(seed_tracks), 1), 1)
    for seed in seed_tracks:
        exclude = index.mask([seed.item_id])
        for track, distance in index.nearest(seed.embedding, per_seed * 2, exclude):
            if track.item_id not in collected or distance < collected[track.item_id]:
                collected[track.item_id] = distance
    ranked = sorted(collected.items(), key=lambda pair: pair[1])[: count * 2]
    rng = random.Random(shuffle_seed)
    rng.shuffle(ranked)
    return [item_id for item_id, _ in ranked[:count]]
