"""Environment-driven configuration (see server/README.md and .env.example)."""

from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class ConfigError(RuntimeError):
    """Raised at startup when required settings are missing or inconsistent."""


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    jellyfin_url: str = "http://jellyfin:8096"
    jellyfin_api_key: str = ""
    # Key the iOS app must send as X-Api-Key.
    sonic_api_key: str = ""
    database_path: str = "data/jellyamp.sqlite"

    # --- analysis ---------------------------------------------------------
    # auto = Essentia/MusiCNN when installed and its model file exists,
    # otherwise the built-in DSP backend (ffmpeg + numpy).
    analysis_backend: Literal["auto", "dsp", "essentia", "none"] = "auto"
    # Seconds of audio analyzed per track, taken from the middle of the track.
    # 0 analyzes whole tracks (exact loudness, much more Jellyfin transcoding).
    analysis_clip_seconds: int = Field(default=90, ge=0, le=3600)
    # Parallel track analyses. Each one is a Jellyfin transcode + one ffmpeg.
    analysis_concurrency: int = Field(default=2, ge=1, le=16)
    # A track that failed this many times is skipped until it changes in
    # Jellyfin or the extractor changes (one corrupt file must not be
    # re-downloaded on every scan forever).
    analysis_max_attempts: int = Field(default=3, ge=1, le=20)
    musicnn_model_path: str = "models/msd-musicnn-1.pb"
    ffmpeg_path: str = "ffmpeg"

    # --- scanning ---------------------------------------------------------
    scan_interval_minutes: int = Field(default=60, ge=1)
    # Delay before the first scan so the container is healthy before work starts.
    scan_startup_delay_seconds: int = Field(default=10, ge=0)

    # --- Sonic Sage (optional LLM playlists) ------------------------------
    anthropic_api_key: str = ""
    sage_model: str = "claude-opus-5-5"

    log_level: str = "INFO"


settings = Settings()


def validate(config: Settings) -> None:
    """Fails fast with an actionable message instead of serving 401s forever."""
    problems: list[str] = []
    if not config.sonic_api_key:
        problems.append(
            "SONIC_API_KEY is not set. Choose a long random string (e.g. `openssl rand -hex 32`) "
            "and enter the same value in the Jellyamp app under Settings → Sonic Server."
        )
    elif len(config.sonic_api_key) < 16:
        problems.append("SONIC_API_KEY is too short; use at least 16 characters.")
    if not config.jellyfin_api_key:
        problems.append(
            "JELLYFIN_API_KEY is not set. Create one in Jellyfin: Dashboard → API Keys → +."
        )
    if not config.jellyfin_url.startswith(("http://", "https://")):
        problems.append(
            f"JELLYFIN_URL must start with http:// or https:// (got {config.jellyfin_url!r})."
        )
    if problems:
        raise ConfigError(
            "jellyamp-server is not configured:\n  - "
            + "\n  - ".join(problems)
            + "\nSee server/README.md (copy .env.example to .env)."
        )
