"""jellyamp-server: the optional sonic-analysis companion for Jellyamp.

Implements the REST contract in docs/SONIC-API.md. All item IDs are Jellyfin
item IDs; the iOS app resolves them to metadata through Jellyfin.
"""

import asyncio
import hmac
import logging
import random
import time
from contextlib import asynccontextmanager
from typing import Annotated, Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Path, Query
from pydantic import BaseModel, Field

from jellyamp_server import config as config_module
from jellyamp_server.analysis.base import Extractor, ident
from jellyamp_server.analysis.extractor import select_extractor
from jellyamp_server.config import settings
from jellyamp_server.jellyfin import JellyfinClient
from jellyamp_server.scanner import LIBRARY_TOTAL_KEY, Scanner
from jellyamp_server.sonic import adventure, mixes, sage, similarity
from jellyamp_server.store import EmbeddingStore, TrackRecord

logger = logging.getLogger(__name__)

API_VERSION = "1.1"
# Jellyfin's server ID never changes; re-check occasionally in case the
# server was unreachable (empty ID) or the URL was repointed.
SERVER_ID_TTL_SECONDS = 300.0

ItemId = Annotated[str, Path(min_length=1, max_length=64)]

# ----------------------------------------------------------------- schemas


class AnalysisInfo(BaseModel):
    backend: str
    version: str


class ScanInfo(BaseModel):
    state: Literal["idle", "scanning"]
    startedAt: str | None = None
    finishedAt: str | None = None
    tracksPending: int
    tracksFailed: int
    lastError: str | None = None


class InfoResponse(BaseModel):
    version: str
    jellyfinServerId: str
    tracksTotal: int
    tracksAnalyzed: int
    capabilities: list[str]
    analysis: AnalysisInfo | None = None
    scan: ScanInfo | None = None


class ScanResponse(BaseModel):
    started: bool
    scan: ScanInfo


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
    type: Literal["genre", "mood", "decade", "style"]
    seed: str = Field(min_length=1, max_length=200)
    count: int = Field(default=100, ge=1, le=500)


class StationResponse(BaseModel):
    itemIds: list[str]


class LoudnessResponse(BaseModel):
    integratedLufs: float
    truePeak: float


class SageRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=1000)
    count: int = Field(default=30, ge=1, le=200)


class SageResponse(BaseModel):
    title: str
    description: str
    itemIds: list[str]


# --------------------------------------------------------------------- app


def create_app(
    store: EmbeddingStore | None = None,
    jellyfin: JellyfinClient | None = None,
    *,
    extractor: Extractor | None = None,
    sage_llm: sage.SageLLM | None = None,
    background_scan: bool | None = None,
) -> FastAPI:
    """App factory.

    Called without arguments (production) everything is built from the
    environment during startup, and misconfiguration aborts with a clear
    message. Tests inject an in-memory store and fakes instead; then no
    background scan runs unless `background_scan=True`.
    """
    production = store is None and jellyfin is None
    state: dict = {
        "store": store,
        "jellyfin": jellyfin,
        "extractor": extractor,
        "sage": sage_llm,
        "scanner": None,
        "server_id": ("", 0.0),
    }

    def make_scanner() -> None:
        if state["jellyfin"] is not None:
            state["scanner"] = Scanner(
                state["jellyfin"],
                state["store"],
                state["extractor"],
                clip_seconds=settings.analysis_clip_seconds,
                concurrency=settings.analysis_concurrency,
                max_attempts=settings.analysis_max_attempts,
            )

    if not production:
        if state["store"] is None:
            state["store"] = EmbeddingStore(":memory:")
        make_scanner()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        scan_loop: asyncio.Task | None = None
        if production:
            logging.basicConfig(
                level=settings.log_level.upper(),
                format="%(asctime)s %(levelname)s %(name)s: %(message)s",
            )
            # httpx logs every request URL at INFO; one line per track is noise.
            logging.getLogger("httpx").setLevel(logging.WARNING)
            config_module.validate(settings)
            active = select_extractor(settings)
            state["extractor"] = active
            state["store"] = EmbeddingStore(
                settings.database_path,
                active_extractor=ident(active) if active else None,
                standardize=bool(active and active.standardize),
                weights=active.weights if active else None,
            )
            state["jellyfin"] = JellyfinClient()
            if settings.anthropic_api_key:
                state["sage"] = sage.AnthropicSageLLM(
                    settings.anthropic_api_key, settings.sage_model
                )
            make_scanner()
            logger.info(
                "jellyamp-server %s: analysis backend %s, Sonic Sage %s",
                API_VERSION,
                ident(active) if active else "none",
                "enabled" if state["sage"] else "disabled",
            )
        scanner: Scanner | None = state["scanner"]
        run_scans = production if background_scan is None else background_scan
        if scanner is not None and run_scans:
            scan_loop = asyncio.create_task(
                scanner.run_forever(
                    settings.scan_interval_minutes * 60, settings.scan_startup_delay_seconds
                ),
                name="scan-loop",
            )
        try:
            yield
        finally:
            if scan_loop is not None:
                scan_loop.cancel()
                await asyncio.gather(scan_loop, return_exceptions=True)
            if scanner is not None:
                await scanner.shutdown()
            if production:
                await state["jellyfin"].aclose()
                if state["sage"] is not None:
                    await state["sage"].aclose()
                state["store"].close()

    app = FastAPI(title="jellyamp-server", version=API_VERSION, lifespan=lifespan)

    # ---------------------------------------------------------- helpers

    def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
        expected = settings.sonic_api_key
        if not expected or not hmac.compare_digest((x_api_key or "").encode(), expected.encode()):
            raise HTTPException(status_code=401, detail="invalid API key")

    def the_store() -> EmbeddingStore:
        return state["store"]

    def capabilities() -> list[str]:
        """Only what can actually be answered right now (docs/SONIC-API.md)."""
        if the_store().count() == 0:
            return []
        caps = ["similar", "adventure", "mixes", "stations"]
        if the_store().loudness_count() > 0:
            caps.append("loudness")
        if state["sage"] is not None:
            caps.append("sage")
        return caps

    def scan_info() -> ScanInfo | None:
        scanner: Scanner | None = state["scanner"]
        if scanner is None:
            return None
        status = scanner.status
        return ScanInfo(
            state="scanning" if scanner.running else "idle",
            startedAt=status.started_at,
            finishedAt=status.finished_at,
            tracksPending=status.pending,
            tracksFailed=len(the_store().exhausted_ids(settings.analysis_max_attempts)),
            lastError=status.last_error,
        )

    async def server_id() -> str:
        cached, fetched_at = state["server_id"]
        client: JellyfinClient | None = state["jellyfin"]
        if client is None or (cached and time.monotonic() - fetched_at < SERVER_ID_TTL_SECONDS):
            return cached
        try:
            cached = await client.server_id()
            state["server_id"] = (cached, time.monotonic())
        except Exception:  # noqa: BLE001 - /info must answer while Jellyfin is down
            logger.warning("jellyfin unreachable for /info")
        return cached

    def track_or_404(item_id: str) -> TrackRecord:
        record = the_store().index().get(item_id)
        if record is None:
            raise HTTPException(status_code=404, detail=f"track {item_id} not analyzed")
        return record

    protected = [Depends(require_api_key)]

    # -------------------------------------------------------- endpoints

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"status": "ok"}

    @app.get("/api/v1/info", response_model=InfoResponse, dependencies=protected)
    async def info() -> InfoResponse:
        analyzed = the_store().count()
        # The scanner records the library size; no Jellyfin round trip here.
        total = int(the_store().get_meta(LIBRARY_TOTAL_KEY) or 0)
        active: Extractor | None = state["extractor"]
        return InfoResponse(
            version=API_VERSION,
            jellyfinServerId=await server_id(),
            tracksTotal=max(total, analyzed),
            tracksAnalyzed=analyzed,
            capabilities=capabilities(),
            analysis=AnalysisInfo(backend=active.name, version=active.version) if active else None,
            scan=scan_info(),
        )

    @app.post("/api/v1/scan", response_model=ScanResponse, status_code=202, dependencies=protected)
    async def scan_endpoint(retryFailed: bool = False) -> ScanResponse:
        scanner: Scanner | None = state["scanner"]
        if scanner is None:
            raise HTTPException(status_code=409, detail="no Jellyfin connection configured")
        started = scanner.trigger(retry_failed=retryFailed)
        return ScanResponse(started=started, scan=scan_info())

    @app.get(
        "/api/v1/similar/tracks/{item_id}", response_model=SimilarResponse, dependencies=protected
    )
    async def similar_tracks_endpoint(
        item_id: ItemId,
        limit: Annotated[int, Query(ge=1, le=500)] = 50,
        excludeSameAlbum: bool = False,
    ) -> SimilarResponse:
        seed = track_or_404(item_id)
        ranked = similarity.similar_tracks(
            seed, the_store().index(), limit=limit, exclude_same_album=excludeSameAlbum
        )
        return SimilarResponse(items=[SimilarItem(itemId=i, distance=d) for i, d in ranked])

    def similar_groups_response(group_id: str, key: str, kind: str, limit: int) -> SimilarResponse:
        ranked = similarity.similar_groups(group_id, the_store().index(), key, limit)
        if not ranked and group_id not in the_store().index().group_centroids(key)[0]:
            raise HTTPException(status_code=404, detail=f"{kind} {group_id} not analyzed")
        return SimilarResponse(items=[SimilarItem(itemId=i, distance=d) for i, d in ranked])

    @app.get(
        "/api/v1/similar/artists/{artist_id}",
        response_model=SimilarResponse,
        dependencies=protected,
    )
    async def similar_artists_endpoint(
        artist_id: ItemId, limit: Annotated[int, Query(ge=1, le=500)] = 20
    ) -> SimilarResponse:
        return similar_groups_response(artist_id, "artist_id", "artist", limit)

    @app.get(
        "/api/v1/similar/albums/{album_id}", response_model=SimilarResponse, dependencies=protected
    )
    async def similar_albums_endpoint(
        album_id: ItemId, limit: Annotated[int, Query(ge=1, le=500)] = 20
    ) -> SimilarResponse:
        return similar_groups_response(album_id, "album_id", "album", limit)

    @app.get("/api/v1/adventure", response_model=AdventureResponse, dependencies=protected)
    async def adventure_endpoint(
        from_id: Annotated[str, Query(alias="from", min_length=1, max_length=64)],
        to: Annotated[str, Query(min_length=1, max_length=64)],
        steps: Annotated[int, Query(ge=1, le=200)] = 20,
    ) -> AdventureResponse:
        if from_id == to:
            raise HTTPException(status_code=422, detail="from and to must be different tracks")
        start = track_or_404(from_id)
        end = track_or_404(to)
        path = adventure.adventure_path(start, end, the_store().index(), steps=steps)
        return AdventureResponse(
            items=[AdventureItem(itemId=i, position=p, distance=d) for i, p, d in path]
        )

    @app.get("/api/v1/mixes", response_model=MixesResponse, dependencies=protected)
    async def mixes_endpoint(
        userId: Annotated[str, Query(min_length=1, max_length=64)],
    ) -> MixesResponse:
        store = the_store()
        index = store.index()
        if len(index) == 0:
            return MixesResponse(mixes=[])
        week = mixes.week_key()
        cached = store.cached_mixes(userId, week)
        if cached is not None:
            built_at_size, payload = cached
            # Keep the week's mixes stable, but not ones built while the
            # first analysis had barely started.
            if payload and built_at_size * 2 >= len(index):
                live = [
                    {**m, "itemIds": [i for i in m["itemIds"] if index.get(i)]} for m in payload
                ]
                return MixesResponse(mixes=[Mix(**m) for m in live if m["itemIds"]])

        recent_ids: list[str] = []
        client: JellyfinClient | None = state["jellyfin"]
        reachable = client is not None
        if client is not None:
            try:
                recent_ids = await client.recently_played_ids(userId)
            except Exception:  # noqa: BLE001 - fall back to library seeding
                reachable = False
                logger.warning("jellyfin unreachable for /mixes")
        recent = [t for t in (index.get(i) for i in recent_ids) if t is not None]
        from_history = bool(recent)
        if not recent:
            # No listening history (yet): seed from the library itself.
            recent = mixes.library_seeds(index)
        built = mixes.build_mixes(recent, index, from_history=from_history)
        if reachable or from_history:
            # Do not pin a week of history-less mixes because of one outage.
            store.cache_mixes(userId, week, len(index), built)
        return MixesResponse(mixes=[Mix(**m) for m in built])

    @app.post("/api/v1/stations", response_model=StationResponse, dependencies=protected)
    async def stations_endpoint(request: StationRequest) -> StationResponse:
        index = the_store().index()
        if request.type == "mood":
            seed = track_or_404(request.seed)
            item_ids = mixes.build_station([seed], index, count=request.count)
        else:
            subset = mixes.station_subset(index, request.type, request.seed)
            if not subset:
                raise HTTPException(
                    status_code=404,
                    detail=f"no analyzed tracks match {request.type} {request.seed!r}",
                )
            if len(subset) <= request.count:
                # Everything that matches fits: play all of it, shuffled.
                item_ids = [t.item_id for t in subset]
                random.shuffle(item_ids)
            else:
                # Sonic ranking within the subset keeps the station coherent
                # instead of a flat random shuffle of the whole genre.
                seeds = subset[:: max(len(subset) // 5, 1)][:5]
                item_ids = mixes.build_station(seeds, index.subset(subset), count=request.count)
                if not item_ids:
                    item_ids = [t.item_id for t in subset[: request.count]]
        return StationResponse(itemIds=item_ids)

    @app.get("/api/v1/loudness/{item_id}", response_model=LoudnessResponse, dependencies=protected)
    async def loudness_endpoint(item_id: ItemId) -> LoudnessResponse:
        record = track_or_404(item_id)
        if record.integrated_lufs is None or record.true_peak is None:
            raise HTTPException(status_code=404, detail=f"no loudness data for {item_id}")
        return LoudnessResponse(integratedLufs=record.integrated_lufs, truePeak=record.true_peak)

    @app.post("/api/v1/sage", response_model=SageResponse, dependencies=protected)
    async def sage_endpoint(request: SageRequest) -> SageResponse:
        llm: sage.SageLLM | None = state["sage"]
        if llm is None:
            raise HTTPException(
                status_code=409, detail="Sonic Sage is disabled (no ANTHROPIC_API_KEY configured)"
            )
        index = the_store().index()
        if len(index) == 0:
            raise HTTPException(status_code=409, detail="no analyzed tracks yet")
        try:
            criteria = await llm.criteria(request.prompt, sage.catalog_summary(index.records))
        except sage.SageError as error:
            # The reason only; never the prompt.
            logger.warning("sage request failed: %s", error)
            raise HTTPException(status_code=502, detail=str(error)) from error
        item_ids = sage.resolve(criteria, index, request.count)
        if not item_ids:
            raise HTTPException(status_code=404, detail="no analyzed tracks match this request")
        return SageResponse(
            title=criteria.title.strip()[:80] or "Sonic Sage",
            description=criteria.description.strip()[:300],
            itemIds=item_ids,
        )

    return app


app = create_app()
