"""Core audio-embedding logic.

Two backends:
  * dummy  — `UX_MUSIC_AUDIO_EMBED_DUMMY=1`: path-derived deterministic vectors,
             no model load. Used for fast tests and Go-side wiring.
  * clap   — laion-clap `music_audioset_epoch_15_esc_90.14.pt` (HTSAT-tiny +
             feature fusion). Lazy-loaded on first request.

Each sidecar invocation is a separate process, so the model is loaded at most
once per invocation. Callers should therefore batch via {songPaths: [...]}.
"""

from __future__ import annotations

import hashlib
import os
import random
from typing import Callable, List, Optional

EMBED_DIM = 512
DUMMY_VERSION = "audio-embed-v0-dummy"
CLAP_VERSION = "audio-embed-v0-clap-music-audioset-htsat-tiny"

ProgressFn = Callable[[str, float], None]

# Lazy singletons. None until first real-mode request loads them.
_clap_model = None  # type: ignore[var-annotated]


def _is_dummy() -> bool:
    return os.environ.get("UX_MUSIC_AUDIO_EMBED_DUMMY", "") == "1"


def _dummy_vector(song_path: str) -> List[float]:
    """Path-derived, reproducible 512-dim vector for tests."""
    digest = hashlib.sha256(song_path.encode("utf-8")).digest()
    seed = int.from_bytes(digest[:8], "big", signed=False)
    rng = random.Random(seed)
    return [rng.uniform(-1.0, 1.0) for _ in range(EMBED_DIM)]


def _normalise_request(req: dict) -> List[str]:
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


def _load_clap():
    """Load the CLAP model on first use. Heavy: ~5s after checkpoint download."""
    global _clap_model
    if _clap_model is not None:
        return _clap_model
    import laion_clap  # imported lazily to keep dummy mode dependency-free

    model = laion_clap.CLAP_Module(enable_fusion=True, amodel="HTSAT-tiny")
    model.load_ckpt(model_id=3)  # music_audioset_epoch_15_esc_90.14.pt
    _clap_model = model
    return model


def _clap_embed_batch(paths: List[str], emit: Optional[ProgressFn]) -> List[List[float]]:
    if emit is not None:
        emit("loading-model", 0.0)
    model = _load_clap()
    if emit is not None:
        emit("encoding-audio", 10.0)
    # laion-clap reads files itself (librosa under the hood) and returns
    # np.ndarray of shape (N, 512).
    vectors = model.get_audio_embedding_from_filelist(x=paths, use_tensor=False)
    if emit is not None:
        emit("encoding-audio", 100.0)
    return [[float(x) for x in row] for row in vectors]


def _dummy_embed_batch(paths: List[str], emit: Optional[ProgressFn]) -> List[List[float]]:
    out: List[List[float]] = []
    total = len(paths)
    for idx, path in enumerate(paths):
        if emit is not None:
            emit("dummy-embed", (idx / max(total, 1)) * 100.0)
        out.append(_dummy_vector(path))
    if emit is not None:
        emit("dummy-embed", 100.0)
    return out


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
    try:
        if dummy:
            vectors = _dummy_embed_batch(paths, emit)
            version = DUMMY_VERSION
        else:
            vectors = _clap_embed_batch(paths, emit)
            version = CLAP_VERSION
    except FileNotFoundError as exc:
        return {"success": False, "error": f"audio not found: {exc}"}
    except Exception as exc:  # noqa: BLE001 — surface any model/runtime error to Go
        return {"success": False, "error": f"{type(exc).__name__}: {exc}"}

    embeddings = [
        {"songPath": path, "vector": vec, "dim": EMBED_DIM}
        for path, vec in zip(paths, vectors)
    ]
    return {"success": True, "version": version, "embeddings": embeddings}
