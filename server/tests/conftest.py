import numpy as np
import pytest

from jellyamp_server.store import EmbeddingStore, TrackRecord


def make_track(
    item_id: str,
    embedding: list[float],
    artist_id: str | None = None,
    album_id: str | None = None,
    lufs: float | None = None,
    peak: float | None = None,
    genres: list[str] | None = None,
    year: int | None = None,
) -> TrackRecord:
    return TrackRecord(
        item_id=item_id,
        embedding=np.array(embedding, dtype=np.float32),
        artist_id=artist_id,
        album_id=album_id,
        integrated_lufs=lufs,
        true_peak=peak,
        genres=genres or [],
        year=year,
    )


@pytest.fixture
def store() -> EmbeddingStore:
    return EmbeddingStore(":memory:")
