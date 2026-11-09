# jellyamp-server
#
# Default (slim) image: fully functional — analyzes with the built-in DSP
# backend, which needs only ffmpeg + numpy. Multi-arch (amd64/arm64).
#
#   docker build -t jellyamp-server .
#
# Optional "full" image with the Essentia/MusiCNN backend (amd64 only, ~2 GB,
# AGPL-3.0 dependency; see README "Analysis backends"):
#
#   docker build --build-arg WITH_ANALYSIS=1 -t jellyamp-server:full .
FROM python:3.11-slim

ARG WITH_ANALYSIS=0
# Where the full image fetches the MusiCNN weights from at build time.
ARG MUSICNN_MODEL_URL=https://essentia.upf.edu/models/feature-extractors/musicnn/msd-musicnn-1.pb

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DATABASE_PATH=/data/jellyamp.sqlite \
    MUSICNN_MODEL_PATH=/models/msd-musicnn-1.pb

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user; /data holds the SQLite database (mount a volume there).
RUN useradd --system --uid 10001 --user-group --home-dir /app jellyamp \
    && mkdir -p /app /data /models \
    && chown jellyamp:jellyamp /data /models

WORKDIR /app

COPY pyproject.toml ./
COPY jellyamp_server ./jellyamp_server

RUN pip install ".[sage]" \
    && if [ "$WITH_ANALYSIS" = "1" ]; then \
         pip install ".[analysis]" \
         && python -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" \
              "$MUSICNN_MODEL_URL" "$MUSICNN_MODEL_PATH" \
         && test -s "$MUSICNN_MODEL_PATH"; \
       fi

USER jellyamp
VOLUME /data
EXPOSE 8095

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8095/healthz', timeout=4)"]

# Validates the configuration first and exits with a readable message when a
# required variable is missing.
CMD ["python", "-m", "jellyamp_server"]
