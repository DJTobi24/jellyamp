"""Async Jellyfin client: enumerate audio items and fetch analysis clips."""

from typing import Any

import httpx

from jellyamp_server.config import settings


class JellyfinClient:
    def __init__(self, base_url: str | None = None, api_key: str | None = None):
        self._base_url = (base_url or settings.jellyfin_url).rstrip("/")
        self._api_key = api_key or settings.jellyfin_api_key
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            headers={"Authorization": f'MediaBrowser Token="{self._api_key}"'},
            timeout=30.0,
        )

    async def server_id(self) -> str:
        response = await self._client.get("/System/Info/Public")
        response.raise_for_status()
        return response.json().get("Id", "")

    async def all_audio_items(self, page_size: int = 1000) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        start = 0
        while True:
            response = await self._client.get(
                "/Items",
                params={
                    "includeItemTypes": "Audio",
                    "recursive": "true",
                    "fields": "ParentId",
                    "startIndex": start,
                    "limit": page_size,
                },
            )
            response.raise_for_status()
            payload = response.json()
            items.extend(payload.get("Items", []))
            start += page_size
            if start >= payload.get("TotalRecordCount", 0):
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
                "limit": limit,
                "userId": user_id,
            },
        )
        response.raise_for_status()
        return [item["Id"] for item in response.json().get("Items", [])]

    async def stream_clip(self, item_id: str) -> bytes:
        """First N seconds as MP3 — cheap, codec-uniform analysis input."""
        response = await self._client.get(
            f"/Audio/{item_id}/universal",
            params={
                "container": "mp3",
                "audioCodec": "mp3",
                "maxStreamingBitrate": 128_000,
            },
        )
        response.raise_for_status()
        return response.content

    async def aclose(self) -> None:
        await self._client.aclose()
