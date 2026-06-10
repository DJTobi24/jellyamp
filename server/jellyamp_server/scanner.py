"""Incremental library scan: diff Jellyfin against the store, analyze new tracks."""

import logging

from jellyamp_server.analysis import extractor
from jellyamp_server.jellyfin import JellyfinClient
from jellyamp_server.store import EmbeddingStore, TrackRecord

logger = logging.getLogger(__name__)


async def scan_once(client: JellyfinClient, store: EmbeddingStore) -> int:
    """Analyzes tracks not yet in the store. Returns number analyzed."""
    if not extractor.is_available():
        logger.warning("essentia not installed - skipping analysis scan")
        return 0

    items = await client.all_audio_items()
    known = store.known_ids()
    pending = [item for item in items if item["Id"] not in known]
    logger.info("scan: %d tracks total, %d pending analysis", len(items), len(pending))

    analyzed = 0
    for item in pending:
        try:
            clip = await client.stream_clip(item["Id"])
            result = extractor.analyze_clip(clip)
            store.upsert(
                TrackRecord(
                    item_id=item["Id"],
                    embedding=result.embedding,
                    artist_id=(item.get("ArtistItems") or [{}])[0].get("Id"),
                    album_id=item.get("AlbumId"),
                    integrated_lufs=result.integrated_lufs,
                    true_peak=result.true_peak,
                )
            )
            analyzed += 1
        except Exception:
            logger.exception("analysis failed for %s", item["Id"])
    return analyzed
