"""Validates API responses against the fixtures shared with the iOS
SonicClient tests (see docs/SONIC-API.md and scripts/sync-fixtures.sh):
same keys, same shapes — contract drift fails here.
"""

import json
from pathlib import Path

import pytest
from conftest import make_track
from fastapi.testclient import TestClient

from jellyamp_server.config import settings
from jellyamp_server.main import create_app
from jellyamp_server.store import EmbeddingStore

FIXTURES = Path(__file__).parent / "fixtures"
API_KEY = "test-key"


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text())


@pytest.fixture
def client(store: EmbeddingStore, monkeypatch) -> TestClient:
    monkeypatch.setattr(settings, "sonic_api_key", API_KEY)
    seed_tracks = [
        make_track("seed", [1, 0, 0], artist_id="art-1", album_id="alb-1", lufs=-9.4, peak=-0.3),
        make_track(
            "close", [0.9, 0.1, 0], artist_id="art-2", album_id="alb-2", lufs=-11.0, peak=-1.0
        ),
        make_track("medium", [0.5, 0.5, 0], artist_id="art-3", album_id="alb-3"),
        make_track("far", [0, 0, 1], artist_id="art-4", album_id="alb-4"),
    ]
    for track in seed_tracks:
        store.upsert(track)
    app = create_app(store=store)
    with TestClient(app) as test_client:
        yield test_client


def auth() -> dict:
    return {"X-Api-Key": API_KEY}


def test_healthz_is_unauthenticated(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_missing_api_key_is_401(client):
    assert client.get("/api/v1/info").status_code == 401
    assert client.get("/api/v1/info", headers={"X-Api-Key": "wrong"}).status_code == 401


def test_info_matches_fixture_shape(client):
    response = client.get("/api/v1/info", headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert set(body) == set(fixture("info"))
    assert body["version"] == "1.0"
    assert body["tracksAnalyzed"] == 4


def test_similar_tracks_matches_fixture_shape(client):
    response = client.get("/api/v1/similar/tracks/seed?limit=3", headers=auth())
    assert response.status_code == 200
    body = response.json()
    expected = fixture("similar_tracks")
    assert set(body) == set(expected)
    assert set(body["items"][0]) == set(expected["items"][0])
    assert [item["itemId"] for item in body["items"]] == ["close", "medium", "far"]


def test_similar_unknown_track_is_404(client):
    assert client.get("/api/v1/similar/tracks/nope", headers=auth()).status_code == 404


def test_adventure_matches_fixture_shape(client):
    response = client.get("/api/v1/adventure?from=seed&to=far&steps=2", headers=auth())
    assert response.status_code == 200
    body = response.json()
    expected = fixture("adventure")
    assert set(body) == set(expected)
    assert set(body["items"][0]) == set(expected["items"][0])
    item_ids = [item["itemId"] for item in body["items"]]
    assert item_ids[0] == "seed"
    assert item_ids[-1] == "far"


def test_mixes_matches_fixture_shape(client):
    response = client.get("/api/v1/mixes?userId=user-1", headers=auth())
    assert response.status_code == 200
    body = response.json()
    expected = fixture("mixes")
    assert set(body) == set(expected)
    if body["mixes"]:
        assert set(body["mixes"][0]) == set(expected["mixes"][0])


def test_mood_station_matches_fixture_shape(client):
    response = client.post(
        "/api/v1/stations",
        headers=auth(),
        json={"type": "mood", "seed": "seed", "count": 3},
    )
    assert response.status_code == 200
    assert set(response.json()) == set(fixture("station"))


def test_genre_station_reports_unavailable(client):
    response = client.post(
        "/api/v1/stations",
        headers=auth(),
        json={"type": "genre", "seed": "Shoegaze", "count": 10},
    )
    assert response.status_code == 409


def test_loudness_matches_fixture(client):
    response = client.get("/api/v1/loudness/seed", headers=auth())
    assert response.status_code == 200
    body = response.json()
    assert set(body) == set(fixture("loudness"))
    assert body["integratedLufs"] == -9.4
    assert body["truePeak"] == -0.3


def test_loudness_without_data_is_404(client):
    assert client.get("/api/v1/loudness/medium", headers=auth()).status_code == 404
