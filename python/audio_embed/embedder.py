"""Core audio-embedding logic.

In dummy mode (`UX_MUSIC_AUDIO_EMBED_DUMMY=1`), deterministic random vectors
are returned without loading any model — used for fast tests and the initial
Go-side wiring before CLAP is plugged in.

The real CLAP path will be added in the next TDD step.
"""

from __future__ import annotations

import hashlib
import os
import random
from typing import Callable, List, Optional

EMBED_DIM = 512
DUMMY_VERSION = "audio-embed-v0-dummy"
REAL_VERSION_PLACEHOLDER = "audio-embed-v0-clap"

ProgressFn = Callable[[str, float], None]


def _is_dummy() -> bool:
    return os.environ.get("UX_MUSIC_AUDIO_EMBED_DUMMY", "") == "1"


def _dummy_vector(song_path: str) -> List[float]:
    """Path-derived, reproducible 512-dim vector.

    Using SHA-256 of the path as the RNG seed gives us:
      - same path → same vector (stable across runs)
      - different paths → different vectors (separable in tests)
    """
    digest = hashlib.sha256(song_path.encode("utf-8")).digest()
    seed = int.from_bytes(digest[:8], "big", signed=False)
    rng = random.Random(seed)
    return [rng.uniform(-1.0, 1.0) for _ in range(EMBED_DIM)]


def _normalise_request(req: dict) -> List[str]:
    """Accept either {songPath} or {songPaths: [...]}. Empty → error upstream."""
    if "songPaths" in req:
        paths = req.get("songPaths")
        if not isinstance(paths, list) or not paths:
            raise ValueError("songPaths must be a non-empty list")
        return [str(p) for p in paths]
    if "songPath" in req:
        path = req.get("songPath")
        if not isinstance(path, str) or not path:
            raise ValueError("songPath must be a non-empty string")
        return [path]
    raise ValueError("request must contain songPath or songPaths")


def embed_request(req: dict, emit: Optional[ProgressFn] = None) -> dict:
    """Process an embedding request and return the result dict.

    Result shape (success):
      {"success": True, "version": "...", "embeddings": [
          {"songPath": "...", "vector": [...512 floats...], "dim": 512}, ...
      ]}
    """
    try:
        paths = _normalise_request(req)
    except ValueError as exc:
        return {"success": False, "error": str(exc)}

    dummy = _is_dummy()
    version = DUMMY_VERSION if dummy else REAL_VERSION_PLACEHOLDER

    if not dummy:
        return {
            "success": False,
            "error": "real CLAP backend not yet implemented; set UX_MUSIC_AUDIO_EMBED_DUMMY=1",
        }

    total = len(paths)
    embeddings: List[dict] = []
    for idx, path in enumerate(paths):
        if emit is not None:
            emit("dummy-embed", (idx / max(total, 1)) * 100.0)
        embeddings.append(
            {"songPath": path, "vector": _dummy_vector(path), "dim": EMBED_DIM}
        )
    if emit is not None:
        emit("dummy-embed", 100.0)

    return {"success": True, "version": version, "embeddings": embeddings}
