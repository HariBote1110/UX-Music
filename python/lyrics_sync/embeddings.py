"""Sentence embedding helpers (multilingual-e5-small) for line↔segment monotone alignment."""

from __future__ import annotations

from functools import lru_cache

import numpy as np


@lru_cache(maxsize=1)
def load_model():
    from sentence_transformers import SentenceTransformer

    name = "intfloat/multilingual-e5-small"
    return SentenceTransformer(name)


def embed_passages(texts: list[str]) -> np.ndarray:
    m = load_model()
    inputs = ["passage: " + (t or "").strip() for t in texts]
    return m.encode(inputs, convert_to_numpy=True, show_progress_bar=False, normalize_embeddings=False)


def embed_queries(texts: list[str]) -> np.ndarray:
    m = load_model()
    inputs = ["query: " + (t or "").strip() for t in texts]
    return m.encode(inputs, convert_to_numpy=True, show_progress_bar=False, normalize_embeddings=False)


def cosine_metrics(a: np.ndarray, b: np.ndarray) -> float:
    denom = (np.linalg.norm(a) * np.linalg.norm(b))
    if denom <= 1e-12:
        return -1.0
    return float(np.dot(a, b) / denom)
