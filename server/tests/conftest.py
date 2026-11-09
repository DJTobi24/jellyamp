import hashlib

import httpx
import numpy as np
import pytest

from jellyamp_server.analysis.base import AnalysisError, AnalysisResult
from jellyamp_server.store import EmbeddingStore, TrackRecord


def make_track(
    item_id: str,
    embedding: list[float],
    artist_id: str | None = None,
    album_id: str | None = None,
    lufs: float | None = None,
    peak: float | None = None,
    genres: list[str] | None = None,
    year: int | None = None,
    title: str | None = None,
    artist_name: str | None = None,
) -> TrackRecord:
    return TrackRecord(
        item_id=item_id,
        embedding=np.array(embedding, dtype=np.float32),
        artist_id=artist_id,
        album_id=album_id,
        integrated_lufs=lufs,
        true_peak=peak,
        genres=genres or [],
        year=year,
        title=title,
        artist_name=artist_name,
    )


@pytest.fixture
def store() -> EmbeddingStore:
    return EmbeddingStore(":memory:")


def jellyfin_item(
    item_id: str,
    name: str = "Track",
    artist: str = "Artist",
    album: str = "Album",
    genre: str = "Rock",
    year: int = 2000,
    seconds: float = 200.0,
) -> dict:
    """An audio item shaped like Jellyfin's `/Items` response."""
    return {
        "Id": item_id,
        "Name": name,
        "ArtistItems": [{"Name": artist, "Id": f"artist-{artist}"}],
        "Album": album,
        "AlbumId": f"album-{album}",
        "Genres": [genre],
        "ProductionYear": year,
        "RunTimeTicks": int(seconds * 10_000_000),
    }


class FakeJellyfin:
    """Stands in for `JellyfinClient`; clips are just the item ID as bytes."""

    def __init__(self, items: list[dict] | None = None):
        self.items = items or []
        self.down = False
        self.broken_clips: set[str] = set()
        self.played: dict[str, list[str]] = {}
        self.clip_requests: list[tuple[str, float | None, int]] = []
        self.listings = 0

    def _check(self) -> None:
        if self.down:
            raise httpx.ConnectError("connection refused")

    async def server_id(self) -> str:
        self._check()
        return "jellyfin-server-id"

    async def all_audio_items(self) -> list[dict]:
        self._check()
        self.listings += 1
        return list(self.items)

    async def recently_played_ids(self, user_id: str, limit: int = 100) -> list[str]:
        self._check()
        return self.played.get(user_id, [])[:limit]

    async def fetch_clip(self, item_id: str, duration=None, clip_seconds: int = 90) -> bytes:
        self._check()
        self.clip_requests.append((item_id, duration, clip_seconds))
        if item_id in self.broken_clips:
            request = httpx.Request("GET", f"http://jellyfin/Audio/{item_id}/stream.mp3")
            raise httpx.HTTPStatusError(
                "500", request=request, response=httpx.Response(500, request=request)
            )
        return item_id.encode()

    async def aclose(self) -> None:
        pass


class FakeExtractor:
    """Deterministic pseudo-embedding from the clip bytes; no audio involved."""

    name = "fake"
    standardize = False
    weights = None
    dim = 8

    def __init__(self, version: str = "1", fail_on: set[str] | None = None):
        self.version = version
        self.fail_on = fail_on or set()
        self.calls: list[str] = []

    def analyze(self, audio_bytes: bytes) -> AnalysisResult:
        item_id = audio_bytes.decode()
        self.calls.append(item_id)
        if item_id in self.fail_on:
            raise AnalysisError("ffmpeg could not decode clip")
        digest = hashlib.sha256(audio_bytes + self.version.encode()).digest()
        embedding = np.frombuffer(digest[: self.dim], dtype=np.uint8).astype(np.float32) + 1.0
        return AnalysisResult(embedding=embedding, integrated_lufs=-14.0, true_peak=-1.0)
