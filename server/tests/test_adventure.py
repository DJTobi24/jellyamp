from conftest import make_track

from jellyamp_server.sonic.adventure import adventure_path


def library():
    # Embeddings laid out on a line from (1,0) to (0,1) so the expected path
    # ordering is obvious.
    return [
        make_track("start", [1.0, 0.0], artist_id="art-start"),
        make_track("quarter", [0.75, 0.25], artist_id="art-q"),
        make_track("half", [0.5, 0.5], artist_id="art-h"),
        make_track("threequarter", [0.25, 0.75], artist_id="art-tq"),
        make_track("end", [0.0, 1.0], artist_id="art-end"),
        make_track("outlier", [-1.0, -1.0], artist_id="art-out"),
    ]


def test_path_includes_endpoints_in_order():
    tracks = library()
    path = adventure_path(tracks[0], tracks[4], tracks, steps=3)
    item_ids = [item_id for item_id, _, _ in path]
    assert item_ids[0] == "start"
    assert item_ids[-1] == "end"
    assert item_ids == ["start", "quarter", "half", "threequarter", "end"]


def test_positions_are_dense():
    tracks = library()
    path = adventure_path(tracks[0], tracks[4], tracks, steps=3)
    assert [position for _, position, _ in path] == list(range(len(path)))


def test_no_duplicate_tracks():
    tracks = library()
    path = adventure_path(tracks[0], tracks[4], tracks, steps=10)
    item_ids = [item_id for item_id, _, _ in path]
    assert len(item_ids) == len(set(item_ids))


def test_artist_dedupe_window():
    tracks = [
        make_track("start", [1.0, 0.0], artist_id="A"),
        make_track("same-artist", [0.7, 0.3], artist_id="A"),
        make_track("other", [0.6, 0.4], artist_id="B"),
        make_track("end", [0.0, 1.0], artist_id="C"),
    ]
    path = adventure_path(tracks[0], tracks[3], tracks, steps=1)
    item_ids = [item_id for item_id, _, _ in path]
    # "same-artist" is sonically closest to the waypoint but blocked by the
    # artist window; "other" must be chosen.
    assert "same-artist" not in item_ids
    assert "other" in item_ids


def test_zero_steps_returns_endpoints():
    tracks = library()
    path = adventure_path(tracks[0], tracks[4], tracks, steps=0)
    assert [item_id for item_id, _, _ in path] == ["start", "end"]
