"""`python -m jellyamp_server`: validate configuration, then serve.

Checking the environment before uvicorn starts turns a missing key into one
readable message and a non-zero exit instead of a traceback (or, worse, a
server that answers every request with 401).
"""

import os
import sys

import uvicorn

from jellyamp_server.analysis.extractor import preflight
from jellyamp_server.config import ConfigError, settings, validate

# sysexits.h EX_CONFIG: lets `restart: unless-stopped` users spot a config
# problem in `docker compose ps` instead of a crash loop with no hint.
EXIT_CONFIG = 78


def main() -> None:
    try:
        validate(settings)
        preflight(settings)
    except ConfigError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(EXIT_CONFIG)
    uvicorn.run(
        "jellyamp_server.main:app",
        host=os.environ.get("HOST", "0.0.0.0"),  # noqa: S104 - a container service
        port=int(os.environ.get("PORT", "8095")),
        log_level=settings.log_level.lower(),
    )


if __name__ == "__main__":
    main()
