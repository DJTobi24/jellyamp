"""`python -m jellyamp_server` (the container's command) fails fast and
readably on a broken configuration."""

import os
import subprocess
import sys


def run(tmp_path, **env: str) -> subprocess.CompletedProcess:
    clean = {k: v for k, v in os.environ.items() if not k.startswith(("JELLYFIN_", "SONIC_"))}
    return subprocess.run(
        [sys.executable, "-m", "jellyamp_server"],
        # An empty working directory: no stray .env file is picked up.
        cwd=tmp_path,
        env={**clean, "PYTHONPATH": os.getcwd(), **env},
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_unconfigured_start_exits_78_and_names_every_missing_variable(tmp_path):
    result = run(tmp_path)
    assert result.returncode == 78
    assert "ERROR: jellyamp-server is not configured" in result.stderr
    assert "SONIC_API_KEY is not set" in result.stderr
    assert "JELLYFIN_API_KEY is not set" in result.stderr
    assert "Traceback" not in result.stderr


def test_impossible_backend_is_reported_before_serving(tmp_path):
    result = run(
        tmp_path,
        JELLYFIN_API_KEY="k",
        SONIC_API_KEY="0123456789abcdef",
        ANALYSIS_BACKEND="dsp",
        FFMPEG_PATH="/nonexistent/ffmpeg",
    )
    assert result.returncode == 78
    assert "ANALYSIS_BACKEND=dsp but ffmpeg binary" in result.stderr
