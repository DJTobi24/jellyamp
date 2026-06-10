"""jellyamp-server: the optional sonic-analysis companion for Jellyamp.

Implements the REST contract in docs/SONIC-API.md. All item IDs are Jellyfin
item IDs; the iOS app resolves them to metadata through Jellyfin.
"""

import logging
from contextlib import asynccontextmanager

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

from jellyamp_server import scanner
from jellyamp_server.analysis import extractor
from jellyamp_server.config import settings
from jellyamp_server.jellyfin import JellyfinClient
from jellyamp_server.sonic import adventure, mixes, similarity
from jellyamp_server.store import EmbeddingStore

logging.basicConfig(level=logging.INFO)

API_VERSION = "1.0"


def create_app(
    store: EmbeddingStore | None = None, jellyfin: JellyfinClient | None = None
) -> FastAPI:
    """App factory so tests can inject an in-memory store and fake client."""
    app_store = store or EmbeddingStore(settings.database_path)
    app_jellyfin = jellyfin

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        nonlocal app_jellyfin
        scheduler = None
        if app_jellyfin is None and settings.jellyfin_api_key:
            app_jellyfin = JellyfinClient()
            scheduler = AsyncIOScheduler()
            scheduler.add_job(
                scanner.scan_once,
                "interval",
                minutes=settings.scan_interval_minutes,
                args=[app_jellyfin, app_store],
                next_run_time=None,
            )
            scheduler.start()
        yield
        if scheduler:
            scheduler.shutdown(wait=False)
        if app_jellyfin:
            await app_jellyfin.aclose()

    app = FastAPI(title="jellyamp-server", version=API_VERSION, lifespan=lifespan)

    def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
        if not settings.sonic_api_key or x_api_key != settings.sonic_api_key:
            raise HTTPException(status_code=401, detail="invalid API key")

    def capabilities() -> list[str]:
        caps = []
        if app_store.count() > 0:
            caps = ["similar", "adventure", "mixes", "stations", "loudness"]
        elif extractor.is_available():
            # Analysis pending but possible: report capabilities so the app
            # can show progress instead of silently falling back.
            caps = ["similar", "adventure", "mixes", "stations", "loudness"]
        return caps

    # ------------------------------------------------------------- schemas

    class InfoResponse(BaseModel):
        version: str
        jellyfinServerId: str
        tracksTotal: int
        tracksAnalyzed: int
        capabilities: list[str]

    class SimilarItem(BaseModel):
        itemId: str
        distance: float

    class SimilarResponse(BaseModel):
        items: list[SimilarItem]

    class AdventureItem(BaseModel):
        itemId: str
        position: int
        distance: float

    class AdventureResponse(BaseModel):
        items: list[AdventureItem]

    class Mix(BaseModel):
        id: str
        title: str
        description: str | None = None
        seedItemIds: list[str]
        itemIds: list[str]

    class MixesResponse(BaseModel):
        mixes: list[Mix]

    class StationRequest(BaseModel):
        type: str = Field(pattern="^(genre|mood|decade|style)$")
        seed: str
        count: int = Field(default=100, ge=1, le=500)

    class StationResponse(BaseModel):
        itemIds: list[str]

    class LoudnessResponse(BaseModel):
        integratedLufs: float
        truePeak: float

    # ------------------------------------------------------------ endpoints

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"status": "ok"}

    @app.get("/api/v1/info", response_model=InfoResponse, dependencies=[Depends(require_api_key)])
    async def info() -> InfoResponse:
        server_id = ""
        total = app_store.count()
        if app_jellyfin is not None:
            try:
                server_id = await app_jellyfin.server_id()
                total = len(await app_jellyfin.all_audio_items())
            except Exception:
                logging.getLogger(__name__).warning("jellyfin unreachable for /info")
        return InfoResponse(
            version=API_VERSION,
            jellyfinServerId=server_id,
            tracksTotal=total,
            tracksAnalyzed=app_store.count(),
            capabilities=capabilities(),
        )

    def get_track_or_404(item_id: str):
        record = app_store.get(item_id)
        if record is None:
            raise HTTPException(status_code=404, detail=f"track {item_id} not analyzed")
        return record

    @app.get(
        "/api/v1/similar/tracks/{item_id}",
        response_model=SimilarResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def similar_tracks_endpoint(
        item_id: str, limit: int = 50, excludeSameAlbum: bool = False
    ) -> SimilarResponse:
        seed = get_track_or_404(item_id)
        ranked = similarity.similar_tracks(
            seed, app_store.all_tracks(), limit=limit, exclude_same_album=excludeSameAlbum
        )
        return SimilarResponse(items=[SimilarItem(itemId=i, distance=d) for i, d in ranked])

    @app.get(
        "/api/v1/similar/artists/{artist_id}",
        response_model=SimilarResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def similar_artists_endpoint(artist_id: str, limit: int = 20) -> SimilarResponse:
        ranked = similarity.similar_groups(artist_id, app_store.all_tracks(), "artist_id", limit)
        if not ranked:
            raise HTTPException(status_code=404, detail=f"artist {artist_id} not analyzed")
        return SimilarResponse(items=[SimilarItem(itemId=i, distance=d) for i, d in ranked])

    @app.get(
        "/api/v1/similar/albums/{album_id}",
        response_model=SimilarResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def similar_albums_endpoint(album_id: str, limit: int = 20) -> SimilarResponse:
        ranked = similarity.similar_groups(album_id, app_store.all_tracks(), "album_id", limit)
        if not ranked:
            raise HTTPException(status_code=404, detail=f"album {album_id} not analyzed")
        return SimilarResponse(items=[SimilarItem(itemId=i, distance=d) for i, d in ranked])

    @app.get(
        "/api/v1/adventure",
        response_model=AdventureResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def adventure_endpoint(
        from_id: str = Query(alias="from"), to: str = Query(), steps: int = 20
    ) -> AdventureResponse:
        start = get_track_or_404(from_id)
        end = get_track_or_404(to)
        path = adventure.adventure_path(start, end, app_store.all_tracks(), steps=steps)
        return AdventureResponse(
            items=[AdventureItem(itemId=i, position=p, distance=d) for i, p, d in path]
        )

    @app.get(
        "/api/v1/mixes",
        response_model=MixesResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def mixes_endpoint(userId: str) -> MixesResponse:
        all_tracks = app_store.all_tracks()
        recent_ids: list[str] = []
        if app_jellyfin is not None:
            try:
                recent_ids = await app_jellyfin.recently_played_ids(userId)
            except Exception:
                logging.getLogger(__name__).warning("jellyfin unreachable for /mixes")
        recent = [t for t in (app_store.get(i) for i in recent_ids) if t is not None]
        if not recent:
            # No listening history reachable: seed from the library itself.
            recent = all_tracks[:20]
        built = mixes.build_mixes(recent, all_tracks)
        return MixesResponse(mixes=[Mix(**m) for m in built])

    @app.post(
        "/api/v1/stations",
        response_model=StationResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def stations_endpoint(request: StationRequest) -> StationResponse:
        all_tracks = app_store.all_tracks()
        if request.type == "mood":
            seed = get_track_or_404(request.seed)
            item_ids = mixes.build_station([seed], all_tracks, count=request.count)
        else:
            # genre/decade/style need Jellyfin metadata to choose seed tracks;
            # served via Jellyfin random query + sonic re-ranking in Phase 3.
            raise HTTPException(
                status_code=409,
                detail=f"station type {request.type!r} requires metadata indexing (Phase 3)",
            )
        return StationResponse(itemIds=item_ids)

    @app.get(
        "/api/v1/loudness/{item_id}",
        response_model=LoudnessResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def loudness_endpoint(item_id: str) -> LoudnessResponse:
        record = get_track_or_404(item_id)
        if record.integrated_lufs is None or record.true_peak is None:
            raise HTTPException(status_code=404, detail=f"no loudness data for {item_id}")
        return LoudnessResponse(integratedLufs=record.integrated_lufs, truePeak=record.true_peak)

    return app


app = create_app()
