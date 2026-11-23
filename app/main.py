"""Phrase API: returns a phrase read from a YAML config file.

The config is read once at startup, so a phrase change needs a restart.
"""
import os

import uvicorn
import yaml
from fastapi import APIRouter, FastAPI

CONFIG_PATH = os.environ.get("CONFIG_PATH", "/etc/phrase-api/config.yaml")
PORT = int(os.environ.get("PORT", "8000"))

with open(CONFIG_PATH) as f:
    PHRASE = yaml.safe_load(f)["phrase"]

router = APIRouter()


@router.get("/")
def phrase():
    return {"phrase": PHRASE}


@router.get("/health")
def health():
    return {"status": "ok"}


app = FastAPI(title="phrase-api")
app.include_router(router)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
