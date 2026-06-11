from conftest import make_track

from jellyamp_server.sonic.similarity import cosine_distance, similar_groups, similar_tracks


def test_cosine_distance_identical_is_zero():
    track = make_track("a", [1, 0, 0])
    assert cosine_distance(track.embedding, track.embedding) < 1e-6


def test_cosine_distance_orthogonal_is_one():
    a = make_track("a", [1, 0, 0])
    b = make_track("b", [0, 1, 0])
    assert abs(cosine_distance(a.embedding, b.embedding) - 1.0) < 1e-6


def test_similar_tracks_ranked_by_distance():
    seed = make_track("seed", [1, 0, 0])
    candidates = [
        seed,
        make_track("close", [0.9, 0.1, 0]),
        make_track("far", [0, 0, 1]),
        make_track("medium", [0.5, 0.5, 0]),
    ]
    ranked = similar_tracks(seed, candidates, limit=3)
    assert [item_id for item_id, _ in ranked] == ["close", "medium", "far"]
    assert ranked[0][1] < ranked[1][1] < ranked[2][1]


def test_similar_tracks_excludes_seed_and_same_album():
    seed = make_track("seed", [1, 0, 0], album_id="album1")
    candidates = [
        seed,
        make_track("same-album", [1, 0, 0], album_id="album1"),
        make_track("other", [0.8, 0.2, 0], album_id="album2"),
    ]
    ranked = similar_tracks(seed, candidates, limit=10, exclude_same_album=True)
    assert [item_id for item_id, _ in ranked] == ["other"]


def test_similar_artists_by_centroid():
    tracks = [
        make_track("a1", [1, 0, 0], artist_id="shoegaze-band"),
        make_track("a2", [0.9, 0.1, 0], artist_id="shoegaze-band"),
        make_track("b1", [0.8, 0.2, 0], artist_id="dreampop-band"),
        make_track("c1", [0, 0, 1], artist_id="metal-band"),
    ]
    ranked = similar_groups("shoegaze-band", tracks, "artist_id", limit=2)
    assert [group_id for group_id, _ in ranked] == ["dreampop-band", "metal-band"]


def test_similar_groups_unknown_seed_returns_empty():
    tracks = [make_track("a1", [1, 0, 0], artist_id="x")]
    assert similar_groups("unknown", tracks, "artist_id", limit=5) == []
