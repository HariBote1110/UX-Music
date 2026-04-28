"""Line↔ASR alignment: embedding-based monotone matching + per-line start times from word timestamps."""

from __future__ import annotations

import os
from typing import Any

import numpy as np

from . import phoneme
from .embeddings import cosine_metrics, embed_passages, embed_queries

# Raw cosine below this (multilingual-e5-sm) often means "wrong ASR block" (e.g. instrumental junk).
_WEAK_EMB_COS = float(os.environ.get("UX_MUSIC_ALIGN_WEAK_COS", "0.24"))
# When the match is weak, restart search from the first segment starting this many seconds
# after the previous vocal end (skips short hallucinations after a long break).
_JUMP_AFTER_WEAK_SEC = float(os.environ.get("UX_MUSIC_ALIGN_WEAK_JUMP_SEC", "2.35"))
# Do not apply the weak jump on the opening lines (would skip short intros).
_MIN_PREV_END_FOR_JUMP = float(os.environ.get("UX_MUSIC_ALIGN_MIN_PREV_FOR_JUMP_SEC", "10.0"))


def _segment_start_time(seg: dict[str, Any]) -> float:
    words = seg.get("words") or []
    if words:
        return min(float(w.get("start", 0.0)) for w in words)
    return float(seg.get("start", 0.0))


def _segment_end_time(seg: dict[str, Any]) -> float:
    words = seg.get("words") or []
    if words:
        return max(float(w.get("end", 0.0)) for w in words)
    return float(seg.get("end", 0.0))


def _segment_word_bonus(seg: dict[str, Any]) -> float:
    """
    Down-rank Whisper segments that look like non-vocal / sparse hallucinations along an
    instrumental gap (few words stretched over many seconds).
    """
    words = seg.get("words") or []
    nw = 0
    for w in words:
        if str(w.get("word", w.get("text", ""))).strip():
            nw += 1
    dur = max(0.001, float(seg.get("end", 0.0)) - float(seg.get("start", 0.0)))
    if nw <= 0:
        return 0.14 if dur < 4.5 else 0.11

    density = nw / dur
    if density < 0.22 and dur > 8.5:
        return 0.32
    if density < 0.32 and dur > 5.0:
        return 0.52
    return min(1.0, 0.28 + 0.72 * min(1.0, nw / 10.0))


def _flatten_words(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    flat: list[dict[str, Any]] = []
    for si, seg in enumerate(segments):
        words = seg.get("words") or []
        for w in words:
            ww = dict(w)
            ww["segment_index"] = si
            flat.append(ww)
    return flat


def _best_segment_in_range(
    line_i: int,
    j_start: int,
    m: int,
    line_embs: np.ndarray,
    seg_embs: np.ndarray,
    segments: list[dict[str, Any]],
) -> tuple[int, float, float]:
    """Pick segment index with highest adjusted score; tie-break towards later audio."""
    best_k = j_start
    best_raw = -2.0
    best_adj = -2.0
    for k in range(j_start, m):
        raw = cosine_metrics(line_embs[line_i], seg_embs[k])
        bonus = _segment_word_bonus(segments[k])
        adj = raw * bonus
        st_k = _segment_start_time(segments[k])
        st_b = _segment_start_time(segments[best_k])
        if adj > best_adj + 1e-7 or (
            abs(adj - best_adj) <= 1e-7 and (st_k > st_b or (st_k == st_b and k > best_k))
        ):
            best_adj = adj
            best_raw = raw
            best_k = k
    return best_k, best_raw, best_adj


def _monotone_greedy_ranges(
    lines: list[str],
    line_embs: np.ndarray,
    seg_embs: np.ndarray,
    segments: list[dict[str, Any]],
) -> list[tuple[int, int]]:
    """Each non-interlude line maps to one segment index range [a,b]; monotone increasing."""
    n = len(lines)
    m = len(seg_embs)
    out: list[tuple[int, int]] = [(-1, -1)] * n
    j = 0
    prev_end = 0.0
    for i in range(n):
        if phoneme.is_interlude(lines[i]):
            continue
        if j >= m:
            out[i] = (m - 1, m - 1) if m else (-1, -1)
            continue
        best_k, best_raw, best_adj = _best_segment_in_range(i, j, m, line_embs, seg_embs, segments)
        if (
            best_raw < _WEAK_EMB_COS
            and prev_end >= _MIN_PREV_END_FOR_JUMP
            and segments
        ):
            min_t = prev_end + _JUMP_AFTER_WEAK_SEC
            j_alt = j
            while j_alt < m and _segment_start_time(segments[j_alt]) < min_t:
                j_alt += 1
            if j_alt > j and j_alt < m:
                alt_k, alt_raw, alt_adj = _best_segment_in_range(
                    i, j_alt, m, line_embs, seg_embs, segments
                )
                if alt_raw > best_raw + 0.012 or alt_adj > best_adj + 0.035:
                    best_k, best_raw, best_adj = alt_k, alt_raw, alt_adj
        out[i] = (best_k, best_k)
        j = best_k + 1
        prev_end = max(prev_end, _segment_end_time(segments[best_k]))
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
    ranges = _monotone_greedy_ranges(lines, line_embs, seg_embs, segments)

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
