"""planning-service — emplois du temps DevHub Campus."""
from __future__ import annotations

import json
import logging
import os
import signal
import sys
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException

LOG_LEVEL = os.getenv("LOG_LEVEL", "info").lower()
PORT = int(os.getenv("PORT", "8080"))

_LEVELS = {"debug": logging.DEBUG, "info": logging.INFO, "warn": logging.WARNING, "error": logging.ERROR}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:  # noqa: D401
        return json.dumps(
            {
                "t": datetime.now(timezone.utc).isoformat(),
                "level": record.levelname.lower(),
                "msg": record.getMessage(),
            }
        )


def _setup_logging() -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(_LEVELS.get(LOG_LEVEL, logging.INFO))
    return logging.getLogger("planning")


log = _setup_logging()

app = FastAPI(title="planning-service", version="0.1.0")

SLOTS = [
    {"id": 1, "cours": "Architecture logicielle", "salle": "B12", "debut": "08:30", "fin": "12:00"},
    {"id": 2, "cours": "Clusterisation", "salle": "A4", "debut": "13:30", "fin": "17:00"},
    {"id": 3, "cours": "DevOps avancé", "salle": "B14", "debut": "09:00", "fin": "12:30"},
]


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True, "service": "planning"}


@app.get("/slots")
def list_slots() -> list[dict]:
    return SLOTS


@app.get("/slots/{slot_id}")
def get_slot(slot_id: int) -> dict:
    for s in SLOTS:
        if s["id"] == slot_id:
            return s
    raise HTTPException(status_code=404, detail="not found")


def _handle_sigterm(_signum, _frame) -> None:
    log.info("SIGTERM received, shutting down")
    sys.exit(0)


signal.signal(signal.SIGTERM, _handle_sigterm)
log.info("planning up on :%s", PORT)
log.debug("LOG_LEVEL=%s", LOG_LEVEL)
