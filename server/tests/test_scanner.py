import asyncio
import threading

import pytest
from conftest import FakeExtractor, FakeJellyfin, jellyfin_item

from jellyamp_server.analysis.base import ident
from jellyamp_server.scanner import LIBRARY_TOTAL_KEY, MAX_CONSECUTIVE_NETWORK_ERRORS, Scanner
from jellyamp_server.store import EmbeddingStore


def make(items, extractor=None, **options) -> tuple[Scanner, EmbeddingStore, FakeJellyfin]:
    extractor = extractor if extractor is not None else FakeExtractor()
    store = EmbeddingStore(":memory:", active_extractor=ident(extractor))
    jellyfin = FakeJellyfin(items)
    return Scanner(jellyfin, store, extractor, **options), store, jellyfin


def library(count: int) -> list[dict]:
    return [jellyfin_item(f"t{i}", name=f"Song {i}", artist=f"Band {i % 3}") for i in range(count)]


async def test_scan_analyzes_everything_and_stores_metadata():
    scanner, store, _ = make(library(5))
    status = await scanner.run()

    assert status.state == "idle"
    assert (status.analyzed, status.failed, status.pending) == (5, 0, 0)
    assert status.started_at and status.finished_at and status.last_error is None
    assert store.count() == 5
    assert store.get_meta(LIBRARY_TOTAL_KEY) == "5"
    record = store.get("t1")
    assert record.title == "Song 1"
    assert record.artist_name == "Band 1"
    assert record.artist_id == "artist-Band 1"
    assert record.album_id == "album-Album"
    assert record.genres == ["Rock"]
    assert record.year == 2000
    assert record.extractor == "fake/1"
    assert record.integrated_lufs == -14.0


async def test_second_scan_is_incremental():
    extractor = FakeExtractor()
    scanner, store, jellyfin = make(library(3), extractor)
    await scanner.run()
    jellyfin.items.append(jellyfin_item("new"))
    status = await scanner.run()

    assert status.analyzed == 1
    assert extractor.calls.count("t0") == 1
    assert store.count() == 4


async def test_clip_request_carries_duration_and_clip_length():
    scanner, _, jellyfin = make([jellyfin_item("a", seconds=300.0)], clip_seconds=45)
    await scanner.run()
    assert jellyfin.clip_requests == [("a", 300.0, 45)]


async def test_tracks_deleted_from_jellyfin_are_removed():
    scanner, store, jellyfin = make(library(4))
    await scanner.run()
    jellyfin.items = [item for item in jellyfin.items if item["Id"] != "t2"]
    status = await scanner.run()

    assert status.removed == 1
    assert store.get("t2") is None
    assert store.count() == 3
    assert store.get_meta(LIBRARY_TOTAL_KEY) == "3"


async def test_empty_listing_does_not_wipe_a_populated_store():
    scanner, store, jellyfin = make(library(4))
    await scanner.run()
    jellyfin.items = []  # e.g. the media volume is not mounted
    status = await scanner.run()

    assert status.removed == 0
    assert store.count() == 4


async def test_retagged_tracks_get_fresh_metadata_without_reanalysis():
    extractor = FakeExtractor()
    scanner, store, jellyfin = make(library(2), extractor)
    await scanner.run()
    jellyfin.items[0] = jellyfin_item("t0", name="Renamed", genre="Jazz", year=1959)
    await scanner.run()

    record = store.get("t0")
    assert (record.title, record.genres, record.year) == ("Renamed", ["Jazz"], 1959)
    assert extractor.calls.count("t0") == 1


async def test_one_bad_file_does_not_stop_the_scan_and_is_not_retried_forever():
    extractor = FakeExtractor(fail_on={"t1"})
    scanner, store, _ = make(library(3), extractor, max_attempts=2)

    status = await scanner.run()
    assert (status.analyzed, status.failed) == (2, 1)
    assert store.count() == 2
    assert store.exhausted_ids(2) == set()

    await scanner.run()  # second failed attempt: now exhausted
    assert store.exhausted_ids(2) == {"t1"}
    assert store.failures()[0]["error"] == "ffmpeg could not decode clip"

    status = await scanner.run()  # skipped from now on
    assert (status.analyzed, status.failed) == (0, 0)
    assert extractor.calls.count("t1") == 2


async def test_retry_failed_clears_the_failure_budget():
    extractor = FakeExtractor(fail_on={"t1"})
    scanner, store, _ = make(library(2), extractor, max_attempts=1)
    await scanner.run()
    assert store.exhausted_ids(1) == {"t1"}

    extractor.fail_on.clear()  # e.g. the file was repaired
    assert scanner.trigger(retry_failed=True)
    await scanner._task
    assert store.count() == 2
    assert store.exhausted_ids(1) == set()


async def test_http_error_for_one_item_counts_as_that_tracks_failure():
    scanner, store, jellyfin = make(library(3))
    jellyfin.broken_clips = {"t0"}
    status = await scanner.run()

    assert (status.analyzed, status.failed) == (2, 1)
    assert "HTTP 500" in store.failures()[0]["error"]


async def test_jellyfin_down_is_survived_and_reported():
    scanner, store, jellyfin = make(library(3))
    jellyfin.down = True
    status = await scanner.run()

    assert status.state == "idle"
    assert status.last_error.startswith("Jellyfin unreachable")
    assert store.count() == 0

    jellyfin.down = False
    status = await scanner.run()
    assert status.last_error is None
    assert store.count() == 3


async def test_outage_mid_scan_aborts_without_burning_retry_budgets():
    scanner, store, jellyfin = make(library(40), concurrency=1)
    original = jellyfin.fetch_clip

    async def flaky(item_id, duration=None, clip_seconds=90):
        if len(jellyfin.clip_requests) >= 3:
            jellyfin.down = True
        return await original(item_id, duration, clip_seconds)

    jellyfin.fetch_clip = flaky
    status = await scanner.run()

    assert status.analyzed == 3
    assert status.last_error == "Jellyfin became unreachable during the scan"
    assert store.failures() == []  # an outage is not the tracks' fault
    assert len(jellyfin.clip_requests) == 3  # stopped after a few attempts
    assert MAX_CONSECUTIVE_NETWORK_ERRORS < 40


async def test_extractor_change_reanalyzes_everything():
    items = library(3)
    old = FakeExtractor(version="1")
    jellyfin = FakeJellyfin(items)
    path_store = EmbeddingStore(":memory:", active_extractor=ident(old))
    await Scanner(jellyfin, path_store, old).run()
    assert path_store.count() == 3

    # Same database, new extractor: old embeddings are not served …
    new = FakeExtractor(version="2")
    path_store._active = ident(new)
    path_store._index = None
    assert path_store.count() == 0
    assert len(path_store.index()) == 0

    # … and the next scan replaces them.
    status = await Scanner(jellyfin, path_store, new).run()
    assert status.analyzed == 3
    assert path_store.count() == 3
    assert {path_store.get(f"t{i}").extractor for i in range(3)} == {"fake/2"}


async def test_without_extractor_scan_only_syncs_the_library():
    store = EmbeddingStore(":memory:")
    scanner = Scanner(FakeJellyfin(library(3)), store, None)
    status = await scanner.run()

    assert (status.analyzed, status.failed, status.last_error) == (0, 0, None)
    assert store.get_meta(LIBRARY_TOTAL_KEY) == "3"


async def test_concurrency_is_bounded_and_analysis_runs_off_the_event_loop():
    lock = threading.Lock()
    state = {"active": 0, "peak": 0}
    loop_thread = threading.get_ident()
    threads: set[int] = set()

    class SlowExtractor(FakeExtractor):
        def analyze(self, audio_bytes: bytes):
            threads.add(threading.get_ident())
            with lock:
                state["active"] += 1
                state["peak"] = max(state["peak"], state["active"])
            threading.Event().wait(0.02)
            with lock:
                state["active"] -= 1
            return super().analyze(audio_bytes)

    scanner, store, _ = make(library(12), SlowExtractor(), concurrency=3)

    ticks = 0

    async def heartbeat():
        nonlocal ticks
        while True:
            await asyncio.sleep(0.005)
            ticks += 1

    beat = asyncio.create_task(heartbeat())
    await scanner.run()
    beat.cancel()

    assert store.count() == 12
    assert 2 <= state["peak"] <= 3
    assert loop_thread not in threads
    assert ticks >= 5, "event loop was blocked during analysis"


async def test_trigger_refuses_to_start_a_second_scan():
    release = threading.Event()

    class BlockingExtractor(FakeExtractor):
        def analyze(self, audio_bytes: bytes):
            release.wait(2)
            return super().analyze(audio_bytes)

    scanner, _, _ = make(library(1), BlockingExtractor())
    assert scanner.trigger() is True
    await asyncio.sleep(0.05)
    assert scanner.running
    assert scanner.status.state == "scanning"
    assert scanner.status.pending == 1
    assert scanner.trigger() is False
    release.set()
    await scanner._task
    assert not scanner.running


async def test_run_forever_scans_after_startup_then_on_the_interval():
    scanner, store, jellyfin = make(library(2))
    loop = asyncio.create_task(scanner.run_forever(interval_seconds=0.05, startup_delay=0.01))
    await asyncio.sleep(0.2)
    loop.cancel()
    with pytest.raises(asyncio.CancelledError):
        await loop
    await scanner.shutdown()

    assert store.count() == 2
    assert jellyfin.listings >= 2
