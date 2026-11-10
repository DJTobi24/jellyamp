"""Incremental library scan: diff Jellyfin against the store, analyze the rest.

One scan = list Jellyfin's audio items, drop records of deleted tracks,
refresh tags, then analyze everything the active extractor has not seen yet
with bounded concurrency. Network I/O stays on the event loop; decoding and
feature extraction run in a thread pool so the API keeps answering.
"""

import asyncio
import datetime as dt
import logging
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any

import httpx

from jellyamp_server.analysis.base import AnalysisError, Extractor, ident
from jellyamp_server.jellyfin import JellyfinClient, track_metadata
from jellyamp_server.store import EmbeddingStore, TrackRecord

logger = logging.getLogger(__name__)

# This many network failures in a row mean Jellyfin went away mid-scan: stop
# instead of burning every pending track's retry budget on an outage.
MAX_CONSECUTIVE_NETWORK_ERRORS = 5

LIBRARY_TOTAL_KEY = "library_total"


def _now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


@dataclass
class ScanStatus:
    """Progress of the current scan, or the outcome of the last one."""

    state: str = "idle"  # idle | scanning
    started_at: str | None = None
    finished_at: str | None = None
    # Tracks still to analyze in the running scan (0 when idle).
    pending: int = 0
    analyzed: int = 0  # analyzed by this/the last scan
    failed: int = 0  # failed in this/the last scan
    removed: int = 0  # records dropped because the track left Jellyfin
    last_error: str | None = None
    _network_errors: int = field(default=0, repr=False)


class Scanner:
    def __init__(
        self,
        client: JellyfinClient,
        store: EmbeddingStore,
        extractor: Extractor | None,
        *,
        clip_seconds: int = 90,
        concurrency: int = 2,
        max_attempts: int = 3,
    ):
        self._client = client
        self._store = store
        self._extractor = extractor
        self._clip_seconds = clip_seconds
        self._concurrency = concurrency
        self._max_attempts = max_attempts
        self._pool = ThreadPoolExecutor(max_workers=concurrency, thread_name_prefix="analysis")
        self._task: asyncio.Task | None = None
        self.status = ScanStatus()

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    def trigger(self, retry_failed: bool = False) -> bool:
        """Starts a scan in the background; False when one is already running."""
        if self.running:
            return False
        if retry_failed:
            self._store.clear_failures()
        self._task = asyncio.create_task(self.run(), name="library-scan")
        return True

    async def run_forever(self, interval_seconds: float, startup_delay: float) -> None:
        """Scan shortly after startup, then on the interval."""
        await asyncio.sleep(startup_delay)
        while True:
            if self.trigger() or self.running:
                await asyncio.shield(self._task)
            await asyncio.sleep(interval_seconds)

    async def shutdown(self) -> None:
        if self._task is not None and not self._task.done():
            self._task.cancel()
            await asyncio.gather(self._task, return_exceptions=True)
        self._pool.shutdown(wait=False, cancel_futures=True)

    async def run(self) -> ScanStatus:
        """One full scan. Never raises (except cancellation): errors end up
        in `status.last_error` and the next interval tries again."""
        self.status = ScanStatus(state="scanning", started_at=_now())
        try:
            await self._scan()
        except asyncio.CancelledError:
            self.status.last_error = "scan cancelled"
            raise
        except httpx.HTTPError as error:
            self.status.last_error = f"Jellyfin unreachable: {_describe(error)}"
            logger.warning("scan aborted: %s", self.status.last_error)
        except Exception as error:  # noqa: BLE001 - the scan loop must survive anything
            self.status.last_error = f"scan failed: {type(error).__name__}: {error}"
            logger.exception("scan failed")
        finally:
            self.status.state = "idle"
            self.status.pending = 0
            self.status.finished_at = _now()
        return self.status

    async def _scan(self) -> None:
        items = await self._client.all_audio_items()
        tracks = {item["Id"]: track_metadata(item) for item in items}
        self._store.set_meta(LIBRARY_TOTAL_KEY, str(len(tracks)))

        stored = self._store.stored_ids()
        if tracks or not stored:
            self.status.removed = self._store.delete(sorted(stored - tracks.keys()))
        else:
            # An empty listing next to a populated store is far more likely an
            # unmounted library than a user deleting everything: keep the data.
            logger.warning("Jellyfin lists no audio items; keeping %d records", len(stored))

        known = self._store.known_ids()
        self._store.update_metadata(
            [_record(tracks[item_id], embedding=None) for item_id in known if item_id in tracks]
        )

        if self._extractor is None:
            logger.info("scan: %d tracks, no analysis backend - nothing to analyze", len(tracks))
            return

        exhausted = self._store.exhausted_ids(self._max_attempts)
        pending = [meta for item_id, meta in tracks.items() if item_id not in known | exhausted]
        self.status.pending = len(pending)
        logger.info(
            "scan: %d tracks, %d analyzed, %d pending, %d skipped after repeated failures, "
            "%d removed",
            len(tracks), len(known & tracks.keys()), len(pending),
            len(exhausted & tracks.keys()), self.status.removed,
        )  # fmt: skip
        if not pending:
            return

        queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        for meta in pending:
            queue.put_nowait(meta)
        workers = [asyncio.create_task(self._worker(queue)) for _ in range(self._concurrency)]
        try:
            await asyncio.gather(*workers)
        finally:
            for worker in workers:
                worker.cancel()
        if self.status._network_errors >= MAX_CONSECUTIVE_NETWORK_ERRORS:
            self.status.last_error = "Jellyfin became unreachable during the scan"
        logger.info(
            "scan finished: %d analyzed, %d failed", self.status.analyzed, self.status.failed
        )

    async def _worker(self, queue: asyncio.Queue) -> None:
        loop = asyncio.get_running_loop()
        extractor = self._extractor
        while self.status._network_errors < MAX_CONSECUTIVE_NETWORK_ERRORS:
            try:
                meta = queue.get_nowait()
            except asyncio.QueueEmpty:
                return
            item_id = meta["item_id"]
            try:
                clip = await self._client.fetch_clip(
                    item_id, meta["duration"], self._clip_seconds
                )
                self.status._network_errors = 0
                result = await loop.run_in_executor(self._pool, extractor.analyze, clip)
                record = _record(meta, result.embedding)
                record.integrated_lufs = result.integrated_lufs
                record.true_peak = result.true_peak
                record.extractor = ident(extractor)
                self._store.upsert(record)
                self.status.analyzed += 1
            except httpx.ReadTimeout:
                # Connected fine but this item's transcode never delivered.
                self._fail(item_id, "Jellyfin timed out transcoding the track")
            except httpx.TransportError as error:
                # Jellyfin's fault, not the track's: do not count an attempt.
                self.status._network_errors += 1
                logger.warning("fetching %s failed: %s", item_id, _describe(error))
            except (AnalysisError, httpx.HTTPStatusError) as error:
                self._fail(item_id, _describe(error))
            except Exception as error:  # noqa: BLE001 - one bad file must not stop the scan
                logger.exception("analysis crashed for %s", item_id)
                self._fail(item_id, f"{type(error).__name__}: {error}")
            finally:
                self.status.pending = max(self.status.pending - 1, 0)

    def _fail(self, item_id: str, reason: str) -> None:
        attempts = self._store.record_failure(item_id, reason)
        self.status.failed += 1
        gave_up = " (giving up)" if attempts >= self._max_attempts else ""
        logger.warning(
            "analysis failed for %s, attempt %d/%d%s: %s",
            item_id, attempts, self._max_attempts, gave_up, reason,
        )  # fmt: skip


def _record(meta: dict[str, Any], embedding) -> TrackRecord:
    fields = {key: value for key, value in meta.items() if key != "duration"}
    return TrackRecord(embedding=embedding, **fields)


def _describe(error: Exception) -> str:
    if isinstance(error, httpx.HTTPStatusError):
        return f"Jellyfin answered HTTP {error.response.status_code}"
    return str(error) or type(error).__name__
