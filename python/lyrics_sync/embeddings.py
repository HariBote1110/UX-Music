"""Sentence embedding helpers (multilingual-e5-small) for line↔segment monotone alignment."""

from __future__ import annotations

import hashlib
from functools import lru_cache

import numpy as np

_FORCE_FALLBACK = False


class _FallbackModel:
    """Offline 時に使う軽量な局所埋め込み。

    ネットワークが無い環境でも `stage3_align` の検証が止まらないように、
    文字 n-gram と文字種の頻度を使った決定論的なベクトルを返す。
    """

    def __init__(self, dim: int = 4096) -> None:
        self.dim = dim

    def encode(
        self,
        inputs,
        convert_to_numpy: bool = True,
        show_progress_bar: bool = False,
        normalize_embeddings: bool = False,
    ):
        arr: list[np.ndarray] = []
        for text in inputs:
            s = str(text or "").lower()
            vec = np.zeros(self.dim, dtype=np.float32)
            if s.strip():
                for i, ch in enumerate(s):
                    if not ch.isspace():
                        h = int.from_bytes(
                            hashlib.blake2b(f"u:{ch}".encode("utf-8", "ignore"), digest_size=4).digest(),
                            "little",
                        )
                        vec[h % self.dim] += 0.8
                    if i + 1 < len(s):
                        bg = s[i : i + 2]
                        h = int.from_bytes(
                            hashlib.blake2b(f"b:{bg}".encode("utf-8", "ignore"), digest_size=4).digest(),
                            "little",
                        )
                        vec[h % self.dim] += 1.5
                    if i + 2 < len(s):
                        tg = s[i : i + 3]
                        h = int.from_bytes(
                            hashlib.blake2b(f"t:{tg}".encode("utf-8", "ignore"), digest_size=4).digest(),
                            "little",
                        )
                        vec[h % self.dim] += 2.0
            if normalize_embeddings:
                n = float(np.linalg.norm(vec))
                if n > 1e-12:
                    vec = vec / n
            arr.append(vec)
        out = np.stack(arr, axis=0) if arr else np.zeros((0, self.dim), dtype=np.float32)
        return out if convert_to_numpy else out.tolist()


_FALLBACK_MODEL = _FallbackModel()


@lru_cache(maxsize=1)
def load_model():
    try:
        from sentence_transformers import SentenceTransformer

        name = "intfloat/multilingual-e5-small"
        return SentenceTransformer(name)
    except Exception:
        return _FALLBACK_MODEL


def _dedupe_inputs(inputs: list[str]) -> tuple[list[str], list[int]]:
    unique: list[str] = []
    positions: dict[str, int] = {}
    indices: list[int] = []
    for text in inputs:
        idx = positions.get(text)
        if idx is None:
            idx = len(unique)
            positions[text] = idx
            unique.append(text)
        indices.append(idx)
    return unique, indices


def _encode(texts: list[str], *, prefix: str) -> np.ndarray:
    global _FORCE_FALLBACK

    inputs = [f"{prefix}: " + (t or "").strip() for t in texts]
    if not inputs:
        return np.zeros((0, 0), dtype=np.float32)
    unique_inputs, indices = _dedupe_inputs(inputs)
    if _FORCE_FALLBACK:
        encoded = _FALLBACK_MODEL.encode(
            unique_inputs,
            convert_to_numpy=True,
            show_progress_bar=False,
            normalize_embeddings=True,
        )
        return encoded[indices]

    m = load_model()
    try:
        encoded = m.encode(
            unique_inputs,
            convert_to_numpy=True,
            show_progress_bar=False,
            normalize_embeddings=True,
        )
        return encoded[indices]
    except Exception:
        _FORCE_FALLBACK = True
        encoded = _FALLBACK_MODEL.encode(
            unique_inputs,
            convert_to_numpy=True,
            show_progress_bar=False,
            normalize_embeddings=True,
        )
        return encoded[indices]


def embed_passages(texts: list[str]) -> np.ndarray:
    return _encode(texts, prefix="passage")


def embed_queries(texts: list[str]) -> np.ndarray:
    return _encode(texts, prefix="query")


def cosine_metrics(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))
