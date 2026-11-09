"""End-to-end test against a real Jellyfin server (opt-in).

    JELLYFIN_URL=http://localhost:8096 JELLYFIN_API_KEY=… pytest -m integration -s

Runs the real pipeline in-process — Jellyfin HTTP client, ffmpeg, the DSP
backend, a temporary database — scans the whole library once and exercises
every endpoint with real IDs. Written for the synthetic library of
`scripts/dev-jellyfin` (five genres with distinct "voices"); the genre
assertions assume a library whose genre tags correspond to how tracks sound.
Skipped unless both environment variables are set. `-s` prints the observed
numbers.
"""

import os
import shutil
import time
from collections import Counter, defaultdict

import httpx
import pytest
from fastapi.testclient import TestClient

from jellyamp_server.analysis.base import ident
from jellyamp_server.analysis.dsp import DSPExtractor
from jellyamp_server.config import settings
from jellyamp_server.jellyfin import JellyfinClient
from jellyamp_server.main import create_app
from jellyamp_server.sonic import mixes as mixes_module
from jellyamp_server.store import EmbeddingStore

JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "")
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "")
API_KEY = "integration-test-key-0123456789"
AUTH = {"X-Api-Key": API_KEY}

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not (JELLYFIN_URL and JELLYFIN_API_KEY),
        reason="set JELLYFIN_URL and JELLYFIN_API_KEY to run against a real Jellyfin",
    ),
    pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed"),
]


class Library:
    """Ground truth read straight from Jellyfin, to judge the server's answers."""

    def __init__(self) -> None:
        with httpx.Client(
            base_url=JELLYFIN_URL,
            headers={"Authorization": f'MediaBrowser Token="{JELLYFIN_API_KEY}"'},
            trust_env=False,
            timeout=30,
        ) as jellyfin:
            items = jellyfin.get(
                "/Items",
                params={
                    "includeItemTypes": "Audio",
                    "recursive": "true",
                    "fields": "Genres,ProductionYear",
                    "limit": 5000,
                },
            ).json()["Items"]
            users = jellyfin.get("/Users").json()
            self.server_id = jellyfin.get("/System/Info/Public").json()["Id"]
        self.items = {item["Id"]: item for item in items}
        self.user_id = os.environ.get("JELLYFIN_USER_ID") or users[0]["Id"]
        self.by_genre: dict[str, list[str]] = defaultdict(list)
        for item in items:
            for genre in item.get("Genres") or []:
                self.by_genre[genre].append(item["Id"])

    def genre(self, item_id: str) -> str:
        return (self.items[item_id].get("Genres") or ["?"])[0]

    def label(self, item_id: str) -> str:
        return f"{self.genre(item_id)}/{self.items[item_id]['Name']}"


@pytest.fixture(scope="module")
def library() -> Library:
    return Library()


@pytest.fixture(scope="module")
def client(library, tmp_path_factory):
    extractor = DSPExtractor()
    store = EmbeddingStore(
        tmp_path_factory.mktemp("integration") / "jellyamp.sqlite",
        active_extractor=ident(extractor),
        standardize=extractor.standardize,
        weights=extractor.weights,
    )
    jellyfin = JellyfinClient(JELLYFIN_URL, JELLYFIN_API_KEY)
    original_key = settings.sonic_api_key
    settings.sonic_api_key = API_KEY
    app = create_app(store=store, jellyfin=jellyfin, extractor=extractor)
    try:
        with TestClient(app) as test_client:
            started = time.monotonic()
            assert test_client.post("/api/v1/scan", headers=AUTH).json()["started"] is True
            # Generous: ~0.3 s per track here, but CI machines vary.
            deadline = started + 30 + 2 * len(library.items)
            while True:
                info = test_client.get("/api/v1/info", headers=AUTH).json()
                if info["scan"]["state"] == "idle" and info["scan"]["finishedAt"]:
                    break
                assert time.monotonic() < deadline, f"scan did not finish: {info['scan']}"
                time.sleep(0.25)
            print(
                f"\n[scan] {info['tracksAnalyzed']}/{info['tracksTotal']} tracks in "
                f"{time.monotonic() - started:.1f}s, failed={info['scan']['tracksFailed']}"
            )
            yield test_client
    finally:
        settings.sonic_api_key = original_key
        store.close()


def test_scan_analyzed_the_whole_library(client, library):
    info = client.get("/api/v1/info", headers=AUTH).json()
    assert info["jellyfinServerId"] == library.server_id
    assert info["tracksTotal"] == len(library.items)
    assert info["tracksAnalyzed"] == len(library.items)
    assert info["analysis"] == {"backend": "dsp", "version": "1"}
    assert info["scan"]["tracksFailed"] == 0
    assert info["scan"]["lastError"] is None
    assert info["capabilities"] == ["similar", "adventure", "mixes", "stations", "loudness"]


def test_second_scan_has_nothing_to_do(client):
    before = client.get("/api/v1/info", headers=AUTH).json()
    assert client.post("/api/v1/scan", headers=AUTH).status_code == 202
    time.sleep(1.0)
    after = client.get("/api/v1/info", headers=AUTH).json()
    assert after["scan"]["state"] == "idle"
    assert after["tracksAnalyzed"] == before["tracksAnalyzed"]


def test_similar_tracks_prefer_the_same_genre(client, library):
    hits: Counter[str] = Counter()
    asked: Counter[str] = Counter()
    for item_id in library.items:
        response = client.get(f"/api/v1/similar/tracks/{item_id}?limit=3", headers=AUTH)
        assert response.status_code == 200
        neighbours = response.json()["items"]
        assert len(neighbours) == 3
        assert item_id not in [n["itemId"] for n in neighbours]
        assert [n["distance"] for n in neighbours] == sorted(n["distance"] for n in neighbours)
        genre = library.genre(item_id)
        assert library.genre(neighbours[0]["itemId"]) == genre, (
            f"nearest neighbour of {library.label(item_id)} is "
            f"{library.label(neighbours[0]['itemId'])}"
        )
        hits[genre] += sum(library.genre(n["itemId"]) == genre for n in neighbours)
        asked[genre] += len(neighbours)
    precision = sum(hits.values()) / sum(asked.values())
    print(
        "\n[similar] same-genre precision@3: "
        + ", ".join(f"{g} {hits[g]}/{asked[g]}" for g in sorted(asked))
        + f" → {precision:.0%} overall"
    )
    assert precision >= 0.9


def test_exclude_same_album(client, library):
    item_id = next(iter(library.items))
    album = library.items[item_id]["AlbumId"]
    neighbours = client.get(
        f"/api/v1/similar/tracks/{item_id}?limit=10&excludeSameAlbum=true", headers=AUTH
    ).json()["items"]
    assert neighbours
    assert all(library.items[n["itemId"]]["AlbumId"] != album for n in neighbours)


def test_similar_artists_and_albums(client, library):
    item = library.items[library.by_genre["Ambient"][0]]
    artist_id = item["ArtistItems"][0]["Id"]
    artists = client.get(f"/api/v1/similar/artists/{artist_id}", headers=AUTH).json()["items"]
    assert artists and artist_id not in [a["itemId"] for a in artists]

    albums = client.get(f"/api/v1/similar/albums/{item['AlbumId']}?limit=1", headers=AUTH).json()
    nearest_album = albums["items"][0]["itemId"]
    genres = {library.genre(i) for i, it in library.items.items() if it["AlbumId"] == nearest_album}
    print(f"\n[albums] nearest album to {item['Album']!r} has genres {sorted(genres)}")
    assert genres == {"Ambient"}


def test_adventure_from_ambient_to_rock(client, library):
    start, end = library.by_genre["Ambient"][0], library.by_genre["Rock"][0]
    response = client.get(f"/api/v1/adventure?from={start}&to={end}&steps=8", headers=AUTH)
    assert response.status_code == 200
    items = response.json()["items"]
    ids = [i["itemId"] for i in items]
    print("\n[adventure] " + " → ".join(library.label(i) for i in ids))
    assert ids[0] == start and ids[-1] == end
    assert len(ids) == len(set(ids)) == 10
    assert [i["position"] for i in items] == list(range(10))
    genres = [library.genre(i) for i in ids]
    assert genres[1] == "Ambient" and genres[-2] == "Rock"
    # A path, not a jumble: once it has left Ambient it does not come back.
    last_ambient = max(i for i, g in enumerate(genres) if g == "Ambient")
    assert all(g == "Ambient" for g in genres[: last_ambient + 1])


def test_genre_station(client, library):
    response = client.post(
        "/api/v1/stations", headers=AUTH, json={"type": "genre", "seed": "jazz", "count": 50}
    )
    assert response.status_code == 200
    ids = response.json()["itemIds"]
    print(f"\n[station genre=jazz] {len(ids)} tracks")
    assert ids and len(ids) == len(set(ids))
    assert set(ids) <= set(library.by_genre["Jazz"])
    assert len(ids) >= len(library.by_genre["Jazz"]) - 1


def test_decade_station(client, library):
    response = client.post(
        "/api/v1/stations", headers=AUTH, json={"type": "decade", "seed": "1990s", "count": 50}
    )
    assert response.status_code == 200
    ids = response.json()["itemIds"]
    years = sorted({library.items[i]["ProductionYear"] for i in ids})
    print(f"\n[station decade=1990s] {len(ids)} tracks, years {years}")
    assert ids and all(1990 <= year <= 1999 for year in years)

    missing = client.post(
        "/api/v1/stations", headers=AUTH, json={"type": "decade", "seed": "1890s", "count": 5}
    )
    assert missing.status_code == 404


def test_mood_station_stays_near_its_seed(client, library):
    seed = library.by_genre["Electronic"][0]
    ids = client.post(
        "/api/v1/stations", headers=AUTH, json={"type": "mood", "seed": seed, "count": 5}
    ).json()["itemIds"]
    assert len(ids) == 5 and seed not in ids
    # A station is a shuffled draw from the seed's neighbourhood (2× count).
    nearest = client.get(f"/api/v1/similar/tracks/{seed}?limit=10", headers=AUTH).json()["items"]
    assert set(ids) <= {n["itemId"] for n in nearest}
    assert sum(library.genre(i) == "Electronic" for i in ids) >= 4


def test_mixes_for_the_user(client, library):
    response = client.get(f"/api/v1/mixes?userId={library.user_id}", headers=AUTH)
    assert response.status_code == 200
    built = response.json()["mixes"]
    week = mixes_module.week_key()
    for mix in built:
        print(
            f"\n[mix] {mix['id']} {mix['title']!r} — {mix['description']} ({len(mix['itemIds'])} tracks)"
        )
    assert built
    assert [m["id"] for m in built] == [f"mix-{week}-{n + 1}" for n in range(len(built))]
    for mix in built:
        assert mix["title"] and mix["description"]
        assert mix["itemIds"] and set(mix["itemIds"]) <= set(library.items)
        assert set(mix["seedItemIds"]) <= set(library.items)
        assert not set(mix["itemIds"]) & set(mix["seedItemIds"])
    # Stable within the week.
    again = client.get(f"/api/v1/mixes?userId={library.user_id}", headers=AUTH).json()["mixes"]
    assert again == built


def test_loudness_for_every_track(client, library):
    per_album: dict[str, list[float]] = defaultdict(list)
    for item_id, item in library.items.items():
        response = client.get(f"/api/v1/loudness/{item_id}", headers=AUTH)
        assert response.status_code == 200, library.label(item_id)
        body = response.json()
        assert -60.0 < body["integratedLufs"] < 0.0
        assert body["integratedLufs"] < body["truePeak"] <= 3.0
        per_album[item["Album"]].append(body["integratedLufs"])
    means = {album: sum(v) / len(v) for album, v in per_album.items()}
    print(
        "\n[loudness] album means (LUFS): "
        + ", ".join(f"{album} {lufs:.1f}" for album, lufs in sorted(means.items()))
    )
    # The dev library is mastered at a different level per album.
    assert max(means.values()) - min(means.values()) > 3.0


def test_unknown_ids_are_404(client):
    assert client.get("/api/v1/similar/tracks/doesnotexist", headers=AUTH).status_code == 404
    assert client.get("/api/v1/loudness/doesnotexist", headers=AUTH).status_code == 404
    assert (
        client.get("/api/v1/adventure?from=doesnotexist&to=alsonot", headers=AUTH).status_code
        == 404
    )


def test_sage_is_disabled_without_a_key(client):
    response = client.post("/api/v1/sage", headers=AUTH, json={"prompt": "calm ambient"})
    assert response.status_code == 409
