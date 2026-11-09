"""Store persistence, the similarity index, configuration and the Jellyfin
client's bounded clip fetch."""

import sqlite3

import httpx
import numpy as np
import pytest
from conftest import make_track

from jellyamp_server import jellyfin
from jellyamp_server.analysis import audio, extractor
from jellyamp_server.analysis.dsp import DSPExtractor
from jellyamp_server.config import ConfigError, Settings, validate
from jellyamp_server.sonic import sage
from jellyamp_server.sonic.index import LibraryIndex
from jellyamp_server.store import SCHEMA_VERSION, EmbeddingStore

# ------------------------------------------------------------------ store


def test_store_roundtrip_keeps_metadata_and_extractor(tmp_path):
    path = tmp_path / "db.sqlite"
    store = EmbeddingStore(path, active_extractor="dsp/1")
    record = make_track(
        "a", [0.25, 0.5], artist_id="ar", album_id="al", lufs=-12.5, peak=-0.8,
        genres=["Jazz", "Bebop"], year=1959, title="Last Call", artist_name="Blue Hour Trio",
    )  # fmt: skip
    record.album_name = "Kind of Late"
    store.upsert(record)
    store.close()

    reopened = EmbeddingStore(path, active_extractor="dsp/1")
    loaded = reopened.get("a")
    assert np.array_equal(loaded.embedding, np.array([0.25, 0.5], dtype=np.float32))
    assert (loaded.title, loaded.artist_name, loaded.album_name) == (
        "Last Call", "Blue Hour Trio", "Kind of Late",
    )  # fmt: skip
    assert (loaded.genres, loaded.year, loaded.extractor) == (["Jazz", "Bebop"], 1959, "dsp/1")
    assert (loaded.integrated_lufs, loaded.true_peak) == (-12.5, -0.8)
    assert reopened.count() == 1 and reopened.loudness_count() == 1


def test_store_serves_only_the_active_extractors_tracks(tmp_path):
    path = tmp_path / "db.sqlite"
    old = EmbeddingStore(path, active_extractor="musicnn/msd-1")
    old.upsert(make_track("a", [1.0] * 200))
    old.close()

    new = EmbeddingStore(path, active_extractor="dsp/1")
    assert new.count() == 0
    assert new.known_ids() == set()
    assert new.stored_ids() == {"a"}  # still there, pending re-analysis
    assert len(new.index()) == 0
    new.upsert(make_track("a", [1.0, 2.0]))
    assert new.count() == 1
    assert new.get("a").extractor == "dsp/1"


def test_database_from_an_older_schema_is_reset_instead_of_crashing(tmp_path):
    path = tmp_path / "db.sqlite"
    legacy = sqlite3.connect(path)
    legacy.execute("CREATE TABLE tracks (item_id TEXT PRIMARY KEY, embedding BLOB NOT NULL)")
    legacy.execute("INSERT INTO tracks VALUES ('old', x'00')")
    legacy.commit()
    legacy.close()

    store = EmbeddingStore(path)
    assert store.count() == 0
    store.upsert(make_track("a", [1, 2], title="works"))
    assert store.get("a").title == "works"
    version = sqlite3.connect(path).execute("PRAGMA user_version").fetchone()[0]
    assert version == SCHEMA_VERSION


def test_failures_count_per_extractor_and_clear_on_success(store):
    assert store.record_failure("a", "boom") == 1
    assert store.record_failure("a", "boom again") == 2
    assert store.exhausted_ids(2) == {"a"}
    assert store.exhausted_ids(3) == set()
    assert store.failures() == [{"itemId": "a", "attempts": 2, "error": "boom again"}]

    store.upsert(make_track("a", [1, 0]))
    assert store.failures() == []

    store.record_failure("b", "x")
    store._active = "other/1"  # a different extractor starts from zero
    assert store.exhausted_ids(1) == set()
    assert store.record_failure("b", "y") == 1


def test_delete_and_metadata_updates_invalidate_the_index(store):
    store.upsert(make_track("a", [1, 0], genres=["Rock"]))
    store.upsert(make_track("b", [0, 1]))
    first = store.index()
    assert store.index() is first

    renamed = make_track("a", [9, 9], genres=["Jazz"], title="New")
    assert store.update_metadata([renamed]) == 1
    assert store.update_metadata([renamed]) == 0  # unchanged: no write
    second = store.index()
    assert second is not first
    assert second.get("a").genres == ["Jazz"]
    assert np.allclose(second.get("a").embedding, [1, 0])  # embedding untouched

    assert store.delete(["b", "missing"]) == 1
    assert len(store.index()) == 1


def test_mixes_cache_is_per_user_and_week(store):
    store.cache_mixes("u1", "2026-w24", 100, [{"id": "mix-2026-w24-1"}])
    assert store.cached_mixes("u1", "2026-w24") == (100, [{"id": "mix-2026-w24-1"}])
    assert store.cached_mixes("u2", "2026-w24") is None
    store.cache_mixes("u1", "2026-w25", 120, [])
    assert store.cached_mixes("u1", "2026-w24") is None  # old weeks are dropped


# ------------------------------------------------------------------ index


def test_index_nearest_is_ranked_masked_and_deterministic():
    tracks = [make_track(f"t{i}", [1.0, i / 10]) for i in range(10)]
    index = LibraryIndex(tracks)
    ranked = index.nearest(np.array([1.0, 0.0]), 4, index.mask(["t0"]))
    assert [t.item_id for t, _ in ranked] == ["t1", "t2", "t3", "t4"]
    assert [d for _, d in ranked] == sorted(d for _, d in ranked)
    assert index.nearest(np.array([1.0, 0.0]), 0) == []
    assert np.allclose(np.linalg.norm(index.matrix, axis=1), 1.0)


def test_index_ties_break_by_insertion_order():
    tracks = [make_track(name, [1.0, 0.0]) for name in ("c", "a", "b")]
    ranked = LibraryIndex(tracks).nearest(np.array([1.0, 0.0]), 3)
    assert [t.item_id for t, _ in ranked] == ["c", "a", "b"]


def test_standardization_makes_small_scale_dimensions_count():
    # Dimension 0 is huge but identical in spirit; dimension 1 separates the
    # two groups yet is tiny in raw units.
    rng = np.random.default_rng(0)
    tracks = [
        make_track(f"{group}{i}", [1000.0 + rng.normal(0, 50), 0.001 * sign + rng.normal(0, 1e-4)])
        for group, sign in (("a", 1), ("b", -1))
        for i in range(6)
    ]
    raw = LibraryIndex(tracks)
    assert raw.nearest(raw.get("a0").embedding, 11)[-1][1] < 1e-6  # all "identical"

    standardized = LibraryIndex(tracks, standardize=True, weights=np.array([0.2, 1.0]))
    neighbours = standardized.nearest(
        standardized.get("a0").embedding, 5, standardized.mask(["a0"])
    )
    assert all(t.item_id.startswith("a") for t, _ in neighbours)


def test_tiny_libraries_are_not_standardized():
    tracks = [make_track("a", [1, 0]), make_track("b", [0, 1])]
    index = LibraryIndex(tracks, standardize=True)
    assert np.allclose(index.get("a").embedding, [1, 0])


def test_index_ignores_embeddings_of_a_stray_dimension():
    tracks = [make_track("a", [1, 0]), make_track("b", [0, 1]), make_track("odd", [1, 2, 3])]
    index = LibraryIndex(tracks)
    assert len(index) == 2 and index.get("odd") is None


def test_subset_keeps_the_library_wide_projection():
    tracks = [
        make_track(f"t{i}", [float(i), 1.0], genres=["x" if i < 5 else "y"]) for i in range(10)
    ]
    index = LibraryIndex(tracks, standardize=True)
    view = index.subset([t for t in index.records if t.genres == ["y"]])
    assert len(view) == 5
    assert np.array_equal(view.get("t7").embedding, index.get("t7").embedding)
    assert view.get("t1") is None


# ----------------------------------------------------------------- config


def good_settings(**overrides) -> Settings:
    values = {
        "jellyfin_url": "http://jellyfin:8096",
        "jellyfin_api_key": "abc",
        "sonic_api_key": "0123456789abcdef",
    }
    return Settings(_env_file=None, **{**values, **overrides})


def test_valid_configuration_passes():
    validate(good_settings())


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"sonic_api_key": ""}, "SONIC_API_KEY is not set"),
        ({"sonic_api_key": "short"}, "SONIC_API_KEY is too short"),
        ({"jellyfin_api_key": ""}, "JELLYFIN_API_KEY is not set"),
        ({"jellyfin_url": "jellyfin:8096"}, "JELLYFIN_URL must start with http"),
    ],
)
def test_invalid_configuration_names_the_problem(overrides, message):
    with pytest.raises(ConfigError, match=message):
        validate(good_settings(**overrides))


def test_all_problems_are_reported_at_once():
    with pytest.raises(ConfigError) as error:
        validate(good_settings(sonic_api_key="", jellyfin_api_key=""))
    assert "SONIC_API_KEY" in str(error.value) and "JELLYFIN_API_KEY" in str(error.value)


def test_out_of_range_numbers_are_rejected_by_the_settings_model():
    with pytest.raises(ValueError):
        good_settings(analysis_concurrency=0)
    with pytest.raises(ValueError):
        good_settings(analysis_backend="magic")


def test_backend_selection(monkeypatch):
    monkeypatch.setattr(audio, "ffmpeg_available", lambda ffmpeg="ffmpeg": True)
    assert isinstance(extractor.select_extractor(good_settings()), DSPExtractor)  # auto → dsp
    assert isinstance(
        extractor.select_extractor(good_settings(analysis_backend="dsp")), DSPExtractor
    )
    assert extractor.select_extractor(good_settings(analysis_backend="none")) is None
    with pytest.raises(ConfigError, match="ANALYSIS_BACKEND=essentia"):
        extractor.select_extractor(good_settings(analysis_backend="essentia"))

    monkeypatch.setattr(audio, "ffmpeg_available", lambda ffmpeg="ffmpeg": False)
    assert extractor.select_extractor(good_settings()) is None  # auto degrades …
    with pytest.raises(ConfigError, match="ffmpeg"):  # … an explicit choice does not
        extractor.select_extractor(good_settings(analysis_backend="dsp"))


# -------------------------------------------------------- jellyfin client


def test_clip_window_takes_the_middle_of_long_tracks():
    assert jellyfin.clip_window(300.0, 90) == (105.0, 90.0)
    assert jellyfin.clip_window(60.0, 90) == (0.0, 90.0)
    assert jellyfin.clip_window(None, 90) == (0.0, 90.0)
    assert jellyfin.clip_window(300.0, 0) == (0.0, None)


async def test_fetch_clip_stops_reading_after_the_byte_budget():
    served = {"bytes": 0}

    class Endless(httpx.AsyncByteStream):
        async def __aiter__(self):
            while True:
                served["bytes"] += 65536
                yield b"\0" * 65536

    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, stream=Endless())

    client = jellyfin.JellyfinClient(
        "http://jellyfin:8096", "key", transport=httpx.MockTransport(handler)
    )
    clip = await client.fetch_clip("abc", duration=600.0, clip_seconds=10)
    await client.aclose()

    budget = int(12.0 * jellyfin.CLIP_BITRATE / 8)
    assert len(clip) == budget
    assert served["bytes"] <= budget + 2 * 65536  # did not keep downloading
    request = requests[0]
    assert request.url.path == "/Audio/abc/stream.mp3"
    assert request.url.params["startTimeTicks"] == str(295 * 10_000_000)
    assert request.url.params["audioBitRate"] == "192000"
    assert request.headers["Authorization"] == 'MediaBrowser Token="key"'


async def test_all_audio_items_pages_until_done():
    def handler(request: httpx.Request) -> httpx.Response:
        start = int(request.url.params["startIndex"])
        limit = int(request.url.params["limit"])
        items = [{"Id": f"i{n}"} for n in range(start, min(start + limit, 5))]
        return httpx.Response(200, json={"Items": items, "TotalRecordCount": 5})

    client = jellyfin.JellyfinClient("http://j", "k", transport=httpx.MockTransport(handler))
    items = await client.all_audio_items(page_size=2)
    await client.aclose()
    assert [i["Id"] for i in items] == ["i0", "i1", "i2", "i3", "i4"]


def test_track_metadata_tolerates_sparse_items():
    meta = jellyfin.track_metadata({"Id": "x"})
    assert meta["item_id"] == "x"
    assert meta["genres"] == [] and meta["artist_id"] is None and meta["duration"] is None

    meta = jellyfin.track_metadata(
        {"Id": "y", "AlbumArtist": "VA", "AlbumArtists": [{"Name": "VA", "Id": "va"}]}
    )
    assert (meta["artist_id"], meta["artist_name"]) == ("va", "VA")


# ------------------------------------------------------------ sage logic


def sage_library() -> LibraryIndex:
    tracks = []
    for g, (genre, axis) in enumerate({"Ambient": [1, 0, 0], "Rock": [0, 1, 0]}.items()):
        for n in range(8):
            vector = [a + 0.03 * n * (i == 2) for i, a in enumerate(axis)]
            tracks.append(
                make_track(
                    f"{genre}-{n}", vector, artist_id=f"{genre}-artist-{n % 2}",
                    lufs=-30.0 + n + 10 * g,
                    genres=[genre], year=1990 + n + 10 * g, title=f"{genre} {n}",
                    artist_name=f"{genre} Artist {n % 2}",
                )
            )  # fmt: skip
    return LibraryIndex(tracks)


def criteria(**fields) -> sage.SageCriteria:
    return sage.SageCriteria(title="t", description="d", **fields)


def test_sage_filters_by_genre_and_years():
    index = sage_library()
    ids = sage.resolve(criteria(genres=["ROCK"], year_from=2000, year_to=2003), index, 10)
    assert sorted(ids) == ["Rock-0", "Rock-1", "Rock-2", "Rock-3"]


def test_sage_seed_artist_anchors_the_selection_and_caps_artists():
    index = sage_library()
    ids = sage.resolve(criteria(seed_artists=["ambient artist 0"]), index, 6)
    assert len(ids) == 6 and all(i.startswith("Ambient") for i in ids)
    per_artist = [index.get(i).artist_id for i in ids]
    assert max(per_artist.count(a) for a in set(per_artist)) <= sage.MAX_TRACKS_PER_ARTIST


def test_sage_seed_track_title_is_matched():
    ids = sage.resolve(criteria(seed_tracks=["rock 5"]), sage_library(), 3)
    assert "Rock-5" in ids and all(i.startswith("Rock") for i in ids)


def test_sage_energy_uses_loudness_as_a_proxy():
    index = sage_library()
    calm = sage.resolve(criteria(genres=["Ambient"], energy="low"), index, 8)
    loud = sage.resolve(criteria(genres=["Ambient"], energy="high"), index, 8)
    assert max(index.get(i).integrated_lufs for i in calm) <= min(
        index.get(i).integrated_lufs for i in loud
    )


def test_sage_relaxes_impossible_combinations_instead_of_returning_nothing():
    ids = sage.resolve(
        criteria(genres=["Ambient"], year_from=2015, year_to=2020), sage_library(), 4
    )
    assert len(ids) == 4 and all(i.startswith("Ambient") for i in ids)
    assert sage.resolve(criteria(genres=["Polka"]), sage_library(), 4) == []
    assert sage.resolve(criteria(), LibraryIndex([]), 4) == []


def test_sage_without_criteria_returns_the_requested_count_without_duplicates():
    ids = sage.resolve(criteria(), sage_library(), 10)
    assert len(ids) == len(set(ids)) == 10


def test_catalog_summary_is_bounded_for_huge_libraries():
    tracks = [
        make_track(str(i), [1.0], genres=[f"Genre {i % 500}"], year=1950 + i % 70,
                   artist_name=f"Artist {i % 5000}")
        for i in range(20000)
    ]  # fmt: skip
    summary = sage.catalog_summary(tracks)
    assert "Tracks: 20000" in summary
    assert "and 4600 more" in summary  # 5000 artists, 400 listed
    assert len(summary) < 12000


class _FakeMessages:
    def __init__(self, response):
        self._response = response
        self.requests: list[dict] = []

    async def parse(self, **request):
        self.requests.append(request)
        return self._response


class _Response:
    def __init__(self, parsed, stop_reason="end_turn"):
        self.parsed_output = parsed
        self.stop_reason = stop_reason


def anthropic_llm(model: str, response: _Response) -> tuple[sage.AnthropicSageLLM, _FakeMessages]:
    pytest.importorskip("anthropic")
    llm = sage.AnthropicSageLLM("sk-ant-test", model)
    messages = _FakeMessages(response)
    llm._client = type(
        "C", (), {"messages": messages, "beta": type("B", (), {"messages": messages})}
    )
    return llm, messages


async def test_anthropic_client_requests_structured_criteria():
    wanted = criteria(genres=["Jazz"])
    llm, messages = anthropic_llm("claude-opus-5-5", _Response(wanted))
    assert await llm.criteria("late night jazz", "Tracks: 3") is wanted

    request = messages.requests[0]
    assert request["model"] == "claude-opus-5-5"
    assert request["output_format"] is sage.SageCriteria
    assert request["fallbacks"] == "default"
    assert "late night jazz" in request["messages"][0]["content"]
    assert "Tracks: 3" in request["messages"][0]["content"]
    assert "late night jazz" not in request["system"]


async def test_anthropic_client_omits_fallbacks_for_models_without_them():
    llm, messages = anthropic_llm("claude-haiku-5-5", _Response(criteria()))
    await llm.criteria("x", "y")
    assert "fallbacks" not in messages.requests[0] and "betas" not in messages.requests[0]


@pytest.mark.parametrize(
    ("response", "message"),
    [
        (_Response(None, "refusal"), "declined"),
        (_Response(None, "max_tokens"), "incomplete"),
        (_Response(None), "incomplete"),
    ],
)
async def test_anthropic_client_turns_unusable_answers_into_sage_errors(response, message):
    llm, _ = anthropic_llm("claude-opus-5-5", response)
    with pytest.raises(sage.SageError, match=message):
        await llm.criteria("x", "y")
