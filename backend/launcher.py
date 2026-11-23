"""Entrypoint for the self-contained Windows Aura Voice AI server."""

from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path
import sys
import traceback


def configure_logging() -> Path:
    log_root = Path(
        os.environ.get("LOCALAPPDATA")
        or (Path.home() / "AppData" / "Local")
    ) / "Aura Voice Studio" / "Logs"
    log_root.mkdir(parents=True, exist_ok=True)
    log_path = log_root / "aura-ai-server.log"

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=[
            logging.FileHandler(log_path, encoding="utf-8"),
            logging.StreamHandler(sys.stderr),
        ],
        force=True,
    )
    return log_path


def main() -> None:
    log_path = configure_logging()
    logger = logging.getLogger("aura_voice.launcher")
    parser = argparse.ArgumentParser(description="Aura Voice local AI speech server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    logger.info("Starting Aura Voice AI server on %s:%s", args.host, args.port)
    logger.info("Startup log: %s", log_path)

    try:
        # Import after logging is ready so packaged import failures are recorded.
        from app.main import app

        import uvicorn

        uvicorn.run(
            app,
            host=args.host,
            port=args.port,
            log_level="info",
            access_log=False,
            server_header=False,
            log_config=None,
        )
        logger.info("Uvicorn server stopped.")
    except BaseException:
        logger.exception("Aura Voice AI server terminated with an exception.")
        raise


if __name__ == "__main__":
    main()
