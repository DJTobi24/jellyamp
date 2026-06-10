import datetime as dt

from conftest import make_track

from jellyamp_server.sonic.mixes import build_mixes, build_station, week_key


def library():
    return [
        make_track(f"lib-{i}", [float(i) / 10, 1.0 - float(i) / 10], artist_id=f"art-{i % 4}")
        for i in range(20)
    ]


def test_week_key_is_stable_within_week():
    assert week_key(dt.date(2026, 6, 10)) == week_key(dt.date(2026, 6, 8))
    assert week_key(dt.date(2026, 6, 10)) != week_key(dt.date(2026, 6, 22))


def test_build_mixes_shapes_match_contract():
    recent = library()[:8]
    mixes = build_mixes(
        recent, library(), max_mixes=2, tracks_per_mix=5, today=dt.date(2026, 6, 10)
    )
    assert mixes, "expected at least one mix"
    for mix in mixes:
        assert set(mix) == {"id", "title", "description", "seedItemIds", "itemIds"}
        assert mix["id"].startswith("mix-2026-w24-")
        assert mix["itemIds"]
        assert len(mix["itemIds"]) <= 5


def test_build_mixes_deterministic_per_week():
    recent = library()[:8]
    first = build_mixes(recent, library(), today=dt.date(2026, 6, 8))
    second = build_mixes(recent, library(), today=dt.date(2026, 6, 10))
    assert first == second


def test_build_mixes_empty_history():
    assert build_mixes([], library()) == []


def test_build_station_fills_count_and_excludes_nothing_twice():
    seeds = [library()[0]]
    item_ids = build_station(seeds, library(), count=5, shuffle_seed=1)
    assert len(item_ids) == 5
    assert len(set(item_ids)) == 5
