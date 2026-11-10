"""API behaviour beyond the fixture shapes: truthful capabilities, scan
status and trigger, parameter validation, mixes, and Sonic Sage."""

import json
import time
from pathlib import Path

import pytest
from conftest import FakeExtractor, FakeJellyfin, jellyfin_item, make_track
from fastapi.testclient import TestClient

from jellyamp_server.analysis.base import ident
from jellyamp_server.config import settings
from jellyamp_server.main import create_app
from jellyamp_server.sonic import mixes, sage
from jellyamp_server.store import EmbeddingStore

FIXTURES = Path(__file__).parent / "fixtures"
API_KEY = "test-key-0123456789"
AUTH = {"X-Api-Key": API_KEY}


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text())


@pytest.fixture(autouse=True)
def api_key(monkeypatch):
    monkeypatch.setattr(settings, "sonic_api_key", API_KEY)


def seeded_store() -> EmbeddingStore:
    store = EmbeddingStore(":memory:")
    genres = {"Ambient": [1, 0, 0], "Rock": [0, 1, 0], "Jazz": [0, 0, 1]}
    for g, (genre, axis) in enumerate(genres.items()):
        for n in range(6):
            vector = [a + 0.05 * n * (i == (g + 1) % 3) for i, a in enumerate(axis)]
            store.upsert(
                make_track(
                    f"{genre.lower()}-{n}",
                    vector,
                    artist_id=f"artist-{genre}-{n % 2}",
                    album_id=f"album-{genre}",
                    lufs=-20.0 + 4 * g + n,
                    peak=-1.0,
                    genres=[genre],
                    year=1970 + 20 * g + n,
                    title=f"{genre} Song {n}",
                    artist_name=f"{genre} Band {n % 2}",
                )
            )
    return store


class FakeSage:
    def __init__(self, criteria: sage.SageCriteria | None = None, error: str | None = None):
        self._criteria = criteria
        self._error = error
        self.calls: list[tuple[str, str]] = []

    async def criteria(self, prompt: str, catalog: str) -> sage.SageCriteria:
        self.calls.append((prompt, catalog))
        if self._error:
            raise sage.SageError(self._error)
        return self._criteria


def client_for(store=None, jellyfin=None, **kwargs) -> TestClient:
    return TestClient(create_app(store=store or seeded_store(), jellyfin=jellyfin, **kwargs))


# ------------------------------------------------------------ capabilities


def test_empty_store_reports_no_capabilities():
    with client_for(EmbeddingStore(":memory:")) as client:
        body = client.get("/api/v1/info", headers=AUTH).json()
    assert body["capabilities"] == []
    assert body["tracksAnalyzed"] == 0


def test_loudness_capability_requires_loudness_data():
    store = EmbeddingStore(":memory:")
    store.upsert(make_track("a", [1, 0]))
    store.upsert(make_track("b", [0, 1]))
    with client_for(store) as client:
        assert client.get("/api/v1/info", headers=AUTH).json()["capabilities"] == [
            "similar", "adventure", "mixes", "stations",
        ]  # fmt: skip
    store.upsert(make_track("c", [1, 1], lufs=-9.0, peak=-0.5))
    with client_for(store) as client:
        assert "loudness" in client.get("/api/v1/info", headers=AUTH).json()["capabilities"]


def test_sage_capability_requires_a_configured_model():
    with client_for() as client:
        assert "sage" not in client.get("/api/v1/info", headers=AUTH).json()["capabilities"]
    with client_for(sage_llm=FakeSage()) as client:
        assert "sage" in client.get("/api/v1/info", headers=AUTH).json()["capabilities"]


# -------------------------------------------------------------- info / scan


def test_info_matches_fixture_and_reports_analysis_and_scan():
    jellyfin = FakeJellyfin([jellyfin_item(f"t{i}") for i in range(3)])
    extractor = FakeExtractor()
    store = EmbeddingStore(":memory:", active_extractor=ident(extractor))
    with client_for(store, jellyfin, extractor=extractor) as client:
        body = client.get("/api/v1/info", headers=AUTH).json()
        assert set(body) == set(fixture("info"))
        assert set(body["scan"]) == set(fixture("info")["scan"])
        assert body["analysis"] == {"backend": "fake", "version": "1"}
        assert body["jellyfinServerId"] == "jellyfin-server-id"
        assert body["scan"]["state"] == "idle"
        assert body["scan"]["startedAt"] is None


def test_info_without_jellyfin_omits_scan_status():
    with client_for() as client:
        body = client.get("/api/v1/info", headers=AUTH).json()
    assert body["scan"] is None
    assert body["analysis"] is None
    assert body["tracksTotal"] == body["tracksAnalyzed"] == 18


def test_info_does_not_list_the_library_and_survives_jellyfin_outage():
    jellyfin = FakeJellyfin([jellyfin_item("t0")])
    with client_for(jellyfin=jellyfin) as client:
        for _ in range(3):
            assert client.get("/api/v1/info", headers=AUTH).status_code == 200
        assert jellyfin.listings == 0
        jellyfin.down = True
        body = client.get("/api/v1/info", headers=AUTH).json()
        assert body["jellyfinServerId"] == "jellyfin-server-id"  # cached


def wait_for_idle(client: TestClient) -> dict:
    for _ in range(200):
        body = client.get("/api/v1/info", headers=AUTH).json()
        if body["scan"]["state"] == "idle" and body["scan"]["finishedAt"]:
            return body
        time.sleep(0.01)
    raise AssertionError("scan did not finish")


def test_post_scan_runs_a_scan_and_info_reflects_it():
    jellyfin = FakeJellyfin([jellyfin_item(f"t{i}", genre="Jazz") for i in range(4)])
    extractor = FakeExtractor(fail_on={"t3"})
    store = EmbeddingStore(":memory:", active_extractor=ident(extractor))
    with client_for(store, jellyfin, extractor=extractor) as client:
        response = client.post("/api/v1/scan", headers=AUTH)
        assert response.status_code == 202
        body = response.json()
        assert set(body) == set(fixture("scan"))
        assert body["started"] is True

        info = wait_for_idle(client)
        assert info["tracksTotal"] == 4
        assert info["tracksAnalyzed"] == 3
        assert info["scan"]["tracksPending"] == 0
        assert info["scan"]["lastError"] is None
        assert set(info["capabilities"]) == {
            "similar",
            "adventure",
            "mixes",
            "stations",
            "loudness",
        }


def test_post_scan_without_jellyfin_is_409():
    with client_for() as client:
        assert client.post("/api/v1/scan", headers=AUTH).status_code == 409


def test_post_scan_requires_api_key():
    with client_for() as client:
        assert client.post("/api/v1/scan").status_code == 401


def test_background_scan_runs_shortly_after_startup(monkeypatch):
    monkeypatch.setattr(settings, "scan_startup_delay_seconds", 0)
    jellyfin = FakeJellyfin([jellyfin_item(f"t{i}") for i in range(3)])
    extractor = FakeExtractor()
    store = EmbeddingStore(":memory:", active_extractor=ident(extractor))
    app = create_app(store=store, jellyfin=jellyfin, extractor=extractor, background_scan=True)
    with TestClient(app) as client:
        assert wait_for_idle(client)["tracksAnalyzed"] == 3


# -------------------------------------------------------------- validation


@pytest.mark.parametrize(
    "path",
    [
        "/api/v1/similar/tracks/ambient-0?limit=0",
        "/api/v1/similar/tracks/ambient-0?limit=-5",
        "/api/v1/similar/tracks/ambient-0?limit=100000",
        "/api/v1/similar/tracks/ambient-0?limit=abc",
        "/api/v1/similar/artists/artist-Ambient-0?limit=0",
        "/api/v1/similar/albums/album-Ambient?limit=501",
        "/api/v1/adventure?from=ambient-0&to=rock-0&steps=0",
        "/api/v1/adventure?from=ambient-0&to=rock-0&steps=-1",
        "/api/v1/adventure?from=ambient-0&to=rock-0&steps=1000",
        "/api/v1/adventure?from=ambient-0&to=ambient-0",
        "/api/v1/adventure?from=ambient-0",
        "/api/v1/mixes",
    ],
)
def test_nonsense_query_parameters_are_422(path):
    with client_for() as client:
        assert client.get(path, headers=AUTH).status_code == 422


@pytest.mark.parametrize(
    "body",
    [
        {"type": "genre", "seed": "Rock", "count": 0},
        {"type": "genre", "seed": "Rock", "count": 501},
        {"type": "genre", "seed": "", "count": 10},
        {"type": "tempo", "seed": "Rock", "count": 10},
        {"seed": "Rock"},
    ],
)
def test_nonsense_station_requests_are_422(body):
    with client_for() as client:
        assert client.post("/api/v1/stations", headers=AUTH, json=body).status_code == 422


# ---------------------------------------------------------------- similar


def test_similar_tracks_stay_in_genre_and_respect_limit_and_album_filter():
    with client_for() as client:
        items = client.get("/api/v1/similar/tracks/rock-0?limit=5", headers=AUTH).json()["items"]
        assert [i["itemId"] for i in items] == [f"rock-{n}" for n in range(1, 6)]
        assert items == sorted(items, key=lambda i: i["distance"])

        other = client.get(
            "/api/v1/similar/tracks/rock-0?limit=5&excludeSameAlbum=true", headers=AUTH
        ).json()["items"]
        assert all(not i["itemId"].startswith("rock-") for i in other)


def test_similar_artists_and_albums_use_centroids():
    with client_for() as client:
        artists = client.get("/api/v1/similar/artists/artist-Rock-0", headers=AUTH).json()["items"]
        assert artists[0]["itemId"] == "artist-Rock-1"
        assert len(artists) == 5
        albums = client.get("/api/v1/similar/albums/album-Rock?limit=1", headers=AUTH).json()
        assert len(albums["items"]) == 1
        assert client.get("/api/v1/similar/albums/nope", headers=AUTH).status_code == 404


def test_similarity_uses_the_cached_index_until_a_write(monkeypatch):
    store = seeded_store()
    loads = 0
    original = store.all_tracks

    def counting():
        nonlocal loads
        loads += 1
        return original()

    monkeypatch.setattr(store, "all_tracks", counting)
    with client_for(store) as client:
        for _ in range(5):
            client.get("/api/v1/similar/tracks/rock-0", headers=AUTH)
            client.get("/api/v1/adventure?from=rock-0&to=jazz-0", headers=AUTH)
        assert loads == 1
        store.upsert(make_track("new", [1, 1, 1]))
        ids = client.get("/api/v1/similar/tracks/new?limit=50", headers=AUTH).json()["items"]
        assert len(ids) == 18
        assert loads == 2


def test_adventure_walks_from_one_genre_to_the_other():
    with client_for() as client:
        items = client.get(
            "/api/v1/adventure?from=ambient-0&to=rock-0&steps=6", headers=AUTH
        ).json()["items"]
    ids = [i["itemId"] for i in items]
    assert ids[0] == "ambient-0" and ids[-1] == "rock-0"
    assert [i["position"] for i in items] == list(range(len(items)))
    assert len(set(ids)) == len(ids) == 8
    middle = ids[1:-1]
    assert middle[0].startswith("ambient-") and middle[-1].startswith("rock-")


# ------------------------------------------------------------------ mixes


def test_mixes_from_history_have_stable_ids_titles_and_artist_descriptions():
    jellyfin = FakeJellyfin()
    jellyfin.played["user-1"] = ["rock-0", "rock-1", "rock-2", "jazz-0", "jazz-1", "jazz-2"]
    with client_for(jellyfin=jellyfin) as client:
        first = client.get("/api/v1/mixes?userId=user-1", headers=AUTH).json()["mixes"]
        assert len(first) >= 2
        week = mixes.week_key()
        assert [m["id"] for m in first] == [f"mix-{week}-{n + 1}" for n in range(len(first))]
        titles = {m["title"] for m in first}
        assert {"Rock Mix", "Jazz Mix"} <= titles
        rock = next(m for m in first if m["title"] == "Rock Mix")
        # Artists are listed in order of closeness to the cluster centre.
        assert rock["description"] == "Based on Rock Band 1 and Rock Band 0"
        assert set(rock["seedItemIds"]) <= {"rock-0", "rock-1", "rock-2"}
        assert rock["itemIds"] and not set(rock["itemIds"]) & set(rock["seedItemIds"])
        assert all(i.startswith("rock-") for i in rock["itemIds"][:3])

        # The week's mixes do not reshuffle when the listening history moves on.
        jellyfin.played["user-1"] = ["ambient-0", "ambient-1"]
        assert client.get("/api/v1/mixes?userId=user-1", headers=AUTH).json()["mixes"] == first


def test_mixes_without_history_are_seeded_from_the_library():
    with client_for(jellyfin=FakeJellyfin()) as client:
        built = client.get("/api/v1/mixes?userId=nobody", headers=AUTH).json()["mixes"]
    assert built
    assert all(m["description"].startswith("Around ") for m in built)


def test_mixes_are_empty_without_analyzed_tracks():
    with client_for(EmbeddingStore(":memory:")) as client:
        assert client.get("/api/v1/mixes?userId=u", headers=AUTH).json() == {"mixes": []}


def test_mixes_built_during_an_outage_are_not_pinned_for_the_week():
    jellyfin = FakeJellyfin()
    jellyfin.played["u"] = ["rock-0", "rock-1"]
    jellyfin.down = True
    with client_for(jellyfin=jellyfin) as client:
        offline = client.get("/api/v1/mixes?userId=u", headers=AUTH).json()["mixes"]
        assert offline  # still answers, from the library
        jellyfin.down = False
        online = client.get("/api/v1/mixes?userId=u", headers=AUTH).json()["mixes"]
        assert any(m["description"].startswith("Based on") for m in online)


# ------------------------------------------------------------------- sage


def test_sage_without_model_is_409():
    with client_for() as client:
        response = client.post("/api/v1/sage", headers=AUTH, json={"prompt": "rainy day jazz"})
    assert response.status_code == 409
    assert "ANTHROPIC_API_KEY" in response.json()["detail"]


def test_sage_resolves_criteria_into_an_ordered_playlist():
    llm = FakeSage(
        sage.SageCriteria(
            title="Smoky Late Night", description="Jazz for after midnight.", genres=["jazz"]
        )
    )
    with client_for(sage_llm=llm) as client:
        response = client.post(
            "/api/v1/sage", headers=AUTH, json={"prompt": "late night jazz", "count": 4}
        )
    assert response.status_code == 200
    body = response.json()
    assert set(body) == set(fixture("sage"))
    assert body["title"] == "Smoky Late Night"
    assert body["description"] == "Jazz for after midnight."
    assert len(body["itemIds"]) == 4
    assert all(i.startswith("jazz-") for i in body["itemIds"])

    prompt, catalog = llm.calls[0]
    assert prompt == "late night jazz"
    assert "Tracks: 18" in catalog and "Jazz (6)" in catalog and "Rock Band 0 (3)" in catalog
    assert "1970s" in catalog
    assert "Song" not in catalog  # track titles never leave the server


def test_sage_default_count_and_validation():
    llm = FakeSage(sage.SageCriteria(title="All", description="Everything."))
    with client_for(sage_llm=llm) as client:
        ok = client.post("/api/v1/sage", headers=AUTH, json={"prompt": "anything"})
        assert len(ok.json()["itemIds"]) == 18  # fewer than the default 30 exist
        for bad in ({"prompt": ""}, {"prompt": "x", "count": 0}, {"prompt": "x", "count": 999},
                    {"count": 5}, {"prompt": "x" * 1001}):  # fmt: skip
            assert client.post("/api/v1/sage", headers=AUTH, json=bad).status_code == 422


def test_sage_with_nothing_matching_is_404():
    llm = FakeSage(sage.SageCriteria(title="Polka", description="None here.", genres=["Polka"]))
    with client_for(sage_llm=llm) as client:
        response = client.post("/api/v1/sage", headers=AUTH, json={"prompt": "polka party"})
    assert response.status_code == 404


def test_sage_upstream_failure_is_502_and_never_logs_the_prompt(caplog):
    llm = FakeSage(error="the language model is rate limited; try again later")
    secret_prompt = "songs for my secret surprise party"
    with client_for(sage_llm=llm) as client, caplog.at_level("DEBUG"):
        response = client.post("/api/v1/sage", headers=AUTH, json={"prompt": secret_prompt})
    assert response.status_code == 502
    assert response.json()["detail"] == "the language model is rate limited; try again later"
    assert secret_prompt not in caplog.text


def test_sage_without_analyzed_tracks_is_409():
    with client_for(EmbeddingStore(":memory:"), sage_llm=FakeSage()) as client:
        assert client.post("/api/v1/sage", headers=AUTH, json={"prompt": "x"}).status_code == 409
