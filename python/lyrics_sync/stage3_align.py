"""Line↔ASR alignment: embedding-based monotone matching + per-line start times from word timestamps."""

from __future__ import annotations

from typing import Any

import numpy as np

from . import phoneme
from .embeddings import cosine_metrics, embed_passages, embed_queries


def _flatten_words(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    flat: list[dict[str, Any]] = []
    for si, seg in enumerate(segments):
        words = seg.get("words") or []
        for w in words:
            ww = dict(w)
            ww["segment_index"] = si
            flat.append(ww)
    return flat


def _monotone_greedy_ranges(
    lines: list[str],
    line_embs: np.ndarray,
    seg_embs: np.ndarray,
) -> list[tuple[int, int]]:
    """Each non-interlude line maps to one segment index range [a,b]; monotone increasing."""
    n = len(lines)
    m = len(seg_embs)
    out: list[tuple[int, int]] = [(-1, -1)] * n
    j = 0
    for i in range(n):
        if phoneme.is_interlude(lines[i]):
            continue
        if j >= m:
            out[i] = (m - 1, m - 1) if m else (-1, -1)
            continue
        best_k = j
        best_s = -2.0
        for k in range(j, m):
            s = cosine_metrics(line_embs[i], seg_embs[k])
            if s > best_s:
                best_s = s
                best_k = k
        out[i] = (best_k, best_k)
        j = best_k + 1
    return out


def _interpolate_rows(rows: list[dict[str, Any]]) -> None:
    n = len(rows)
    for idx, row in enumerate(rows):
        if row.get("source") == "interlude":
            continue
        if float(row.get("timestamp", -1.0)) >= 0:
            continue
        prev_t = None
        for j in range(idx - 1, -1, -1):
            tv = rows[j].get("timestamp")
            if tv is not None and float(tv) >= 0:
                prev_t = float(tv)
                break
        next_t = None
        for j in range(idx + 1, n):
            tv = rows[j].get("timestamp")
            if tv is not None and float(tv) >= 0:
                next_t = float(tv)
                break
        if prev_t is not None and next_t is not None:
            row["timestamp"] = (prev_t + next_t) / 2.0
        elif prev_t is not None:
            row["timestamp"] = prev_t + 0.4
        elif next_t is not None:
            row["timestamp"] = max(0.0, next_t - 0.4)
        else:
            row["timestamp"] = 0.0
        row["source"] = "interpolated"
        row["confidence"] = min(float(row.get("confidence", 0.2)), 0.35)


def align(
    lines: list[str],
    segments: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    seg_texts = [str(s.get("text", "")).strip() for s in segments]
    line_embs = embed_queries(lines)
    seg_embs = embed_passages(seg_texts)
    ranges = _monotone_greedy_ranges(lines, line_embs, seg_embs)

    flat = _flatten_words(segments)
    out_lines: list[dict[str, Any]] = []
    matched = 0

    for idx, text in enumerate(lines):
        if phoneme.is_interlude(text):
            out_lines.append(
                {
                    "index": idx,
                    "text": text,
                    "timestamp": -1.0,
                    "confidence": 0.25,
                    "source": "interlude",
                }
            )
            continue

        a, b = ranges[idx] if idx < len(ranges) else (-1, -1)
        if a < 0 or not flat:
            out_lines.append(
                {
                    "index": idx,
                    "text": text,
                    "timestamp": -1.0,
                    "confidence": 0.2,
                    "source": "interpolated",
                }
            )
            continue

        ws = [w for w in flat if a <= int(w.get("segment_index", -1)) <= b]
        if not ws:
            seg = segments[a] if 0 <= a < len(segments) else None
            st = float(seg.get("start", 0.0)) if seg else 0.0
            out_lines.append(
                {
                    "index": idx,
                    "text": text,
                    "timestamp": st,
                    "confidence": 0.45,
                    "source": "match",
                }
            )
            matched += 1
            continue

        lg = phoneme.line_lang(text)
        line_p, _ = phoneme.phoneme_tokens(text)

        scored: list[tuple[float, dict[str, Any]]] = []
        for w in ws:
            tok = str(w.get("word", w.get("text", ""))).strip()
            if not tok:
                continue
            _, wp = phoneme.phoneme_tokens(tok if lg == "ja" else tok)
            if not line_p or not wp:
                overlap = 0.0
            else:
                sa, sb = set(line_p[:12]), set(wp[:8])
                overlap = len(sa & sb) / max(1, len(sa))
            scored.append((overlap, w))
        scored.sort(key=lambda z: z[0], reverse=True)

        picked = ws[0] if not scored else scored[0][1]
        start_ts = float(picked.get("start", ws[0].get("start", 0.0)))

        matched += 1
        confidence = float(0.55 + 0.35 * max(0.0, scored[0][0]) if scored else 0.55)
        out_lines.append(
            {
                "index": idx,
                "text": text,
                "timestamp": start_ts,
                "confidence": min(0.96, confidence),
                "source": "match",
            }
        )

    _interpolate_rows(out_lines)
    detected = [
        {"start": s.get("start"), "end": s.get("end"), "text": s.get("text", "")}
        for s in segments
    ]
    return out_lines, detected
