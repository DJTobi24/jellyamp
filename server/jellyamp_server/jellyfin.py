"""Async Jellyfin client: enumerate audio items and fetch analysis clips."""

from typing import Any

import httpx

from jellyamp_server.config import settings

# Clips are requested as a fixed-bitrate MP3 transcode: every source codec
# becomes one predictable format that can be cut after N bytes ≈ N seconds
# and still decodes (unlike e.g. an MP4 whose index sits at the end).
CLIP_BITRATE = 192_000
# Hard ceiling for whole-track mode (ANALYSIS_CLIP_SECONDS=0): ~44 minutes.
MAX_CLIP_BYTES = 64 * 1024 * 1024
_TICKS_PER_SECOND = 10_000_000


def clip_window(duration: float | None, clip_seconds: int) -> tuple[float, float | None]:
    """(start offset, length) of the analysis clip, both in seconds.

    The clip is taken from the middle of the track: intros and fade-outs are
    the least representative parts. Length None means "to the end".
    """
    if clip_seconds <= 0:
        return 0.0, None
    if not duration or duration <= clip_seconds:
        return 0.0, float(clip_seconds)
    return (duration - clip_seconds) / 2.0, float(clip_seconds)


class JellyfinClient:
    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        self._base_url = (base_url or settings.jellyfin_url).rstrip("/")
        self._api_key = api_key or settings.jellyfin_api_key
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            headers={"Authorization": f'MediaBrowser Token="{self._api_key}"'},
            timeout=httpx.Timeout(30.0, connect=10.0),
            transport=transport,
            # The Jellyfin server is on the local network; never route it
            # through an HTTP(S)_PROXY meant for outbound internet access.
            trust_env=False,
        )

    async def server_id(self) -> str:
        response = await self._client.get("/System/Info/Public")
        response.raise_for_status()
        return response.json().get("Id", "")

    async def all_audio_items(self, page_size: int = 500) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        start = 0
        while True:
            response = await self._client.get(
                "/Items",
                params={
                    "includeItemTypes": "Audio",
                    "recursive": "true",
                    "fields": "Genres,ProductionYear",
                    # A stable order, or pages can skip/repeat items.
                    "sortBy": "SortName",
                    "enableUserData": "false",
                    "enableImages": "false",
                    "startIndex": start,
                    "limit": page_size,
                },
            )
            response.raise_for_status()
            payload = response.json()
            page = payload.get("Items", [])
            items.extend(page)
            start += page_size
            if not page or start >= payload.get("TotalRecordCount", 0):
                return items

    async def recently_played_ids(self, user_id: str, limit: int = 100) -> list[str]:
        response = await self._client.get(
            "/Items",
            params={
                "includeItemTypes": "Audio",
                "recursive": "true",
                "sortBy": "DatePlayed",
                "sortOrder": "Descending",
                "filters": "IsPlayed",
                "enableImages": "false",
                "limit": limit,
                "userId": user_id,
            },
        )
        response.raise_for_status()
        return [item["Id"] for item in response.json().get("Items", [])]

    async def fetch_clip(
        self, item_id: str, duration: float | None = None, clip_seconds: int = 90
    ) -> bytes:
        """At most ~`clip_seconds` of audio as MP3, without downloading the rest.

        The response is streamed and the connection is dropped once enough
        bytes arrived, which also makes Jellyfin stop its transcode.
        """
        start, length = clip_window(duration, clip_seconds)
        params: dict[str, Any] = {"audioCodec": "mp3", "audioBitRate": CLIP_BITRATE}
        if start > 0:
            params["startTimeTicks"] = int(start * _TICKS_PER_SECOND)
        if length is None:
            budget = MAX_CLIP_BYTES
        else:
            # +2 s: MP3 frame padding and encoder delay must not shorten the clip.
            budget = min(int((length + 2.0) * CLIP_BITRATE / 8), MAX_CLIP_BYTES)

        chunks: list[bytes] = []
        received = 0
        async with self._client.stream(
            "GET", f"/Audio/{item_id}/stream.mp3", params=params, timeout=httpx.Timeout(120.0)
        ) as response:
            response.raise_for_status()
            async for chunk in response.aiter_bytes(64 * 1024):
                chunks.append(chunk)
                received += len(chunk)
                if received >= budget:
                    break
        return b"".join(chunks)[:budget]

    async def aclose(self) -> None:
        await self._client.aclose()


def track_metadata(item: dict[str, Any]) -> dict[str, Any]:
    """The fields of a Jellyfin audio item the store keeps."""
    artists = item.get("ArtistItems") or item.get("AlbumArtists") or []
    artist = artists[0] if artists else {}
    ticks = item.get("RunTimeTicks")
    return {
        "item_id": item["Id"],
        "artist_id": artist.get("Id"),
        "album_id": item.get("AlbumId"),
        "genres": item.get("Genres") or [],
        "year": item.get("ProductionYear"),
        "title": item.get("Name"),
        "artist_name": artist.get("Name") or item.get("AlbumArtist"),
        "album_name": item.get("Album"),
        "duration": ticks / _TICKS_PER_SECOND if ticks else None,
    }
