from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Environment-driven configuration (see server/README.md)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    jellyfin_url: str = "http://jellyfin:8096"
    jellyfin_api_key: str = ""
    # Key the iOS app must send as X-Api-Key.
    sonic_api_key: str = ""
    database_path: str = "data/jellyamp.sqlite"
    # Seconds of audio analyzed per track (head of the stream).
    analysis_clip_seconds: int = 90
    # Cron-ish interval for incremental library scans, in minutes.
    scan_interval_minutes: int = 60


settings = Settings()
