# Slim image: API + sonic math. Audio analysis (essentia) is an optional
# extra; build with --build-arg WITH_ANALYSIS=1 for the full analyzer image.
FROM python:3.11-slim

ARG WITH_ANALYSIS=0

WORKDIR /app

COPY pyproject.toml ./
COPY jellyamp_server ./jellyamp_server

RUN pip install --no-cache-dir . \
    && if [ "$WITH_ANALYSIS" = "1" ]; then pip install --no-cache-dir ".[analysis]"; fi

VOLUME /app/data
EXPOSE 8095

HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8095/healthz')"

CMD ["uvicorn", "jellyamp_server.main:app", "--host", "0.0.0.0", "--port", "8095"]
