"""Line↔ASR alignment: embedding-based monotone matching + per-line start times from word timestamps."""

from __future__ import annotations

import os
from typing import Any

import numpy as np

from . import phoneme
from .embeddings import cosine_metrics, embed_passages, embed_queries


def _char_bigram_precision(query: str, passage: str, n: int = 2) -> float:
    """歌詞行と ASR セグメント文字列の surface 類似度（共有バイグラム ÷ 歌詞側バイグラム数）。

    「眺め」対「まだ」のように埋め込みが紛れる近音ミスでも、末尾の同一フレーズで
    スコアが立ち、単語単位の音素比較より失敗しにくい。
    """
    q = query.strip()
    p = passage.strip()
    if not q or len(q) < n:
        return 0.0
    q_ng = {q[i : i + n] for i in range(len(q) - n + 1)}
    p_ng = {p[i : i + n] for i in range(max(0, len(p) - n + 1))}
    if not q_ng:
        return 0.0
    return len(q_ng & p_ng) / len(q_ng)


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
    seg_texts: list[str],
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
        li = lines[i].strip()
        w_emb = float(os.environ.get("UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT", "0.52"))
        w_emb = max(0.0, min(1.0, w_emb))
        w_bg = 1.0 - w_emb
        for k in range(j, m):
            c = cosine_metrics(line_embs[i], seg_embs[k])
            g = _char_bigram_precision(li, seg_texts[k]) if k < len(seg_texts) else 0.0
            # ASR と歌詞の字面一致はコサインだけより先行語誤認に強い。
            # ``UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT`` で埋め込み寄り／字面寄りを調整し、手動参照との MAE を詰める。
            s = w_emb * float(c) + w_bg * float(g)
            if s > best_s:
                best_s = s
                best_k = k
        out[i] = (best_k, best_k)
        j = best_k + 1
    return out


def _interpolate_rows(rows: list[dict[str, Any]]) -> None:
    """時刻未確定の行へタイムスタンプを割り当てる。

    以前は同一アンカー間の複数行すべてに ``(prev+next)/2`` を入れており、再生では
    隣接する前行が異常に長くハイライトされることがあった（    見かけ上「数分そのまま」）。
    アンカー間は線形分割し、先頭・末尾は一定ステップで追記する。
    """
    n = len(rows)
    step = float(os.environ.get("UX_MUSIC_SYNC_INTERPOLATE_STEP_SECONDS", "2.5"))

    def _is_anchor(i: int) -> bool:
        if rows[i].get("source") == "interlude":
            return False
        return float(rows[i].get("timestamp", -1.0)) >= 0

    anchor_indices = [i for i in range(n) if _is_anchor(i)]

    def _fill_between(lo: int, hi: int, t_lo: float, t_hi: float) -> None:
        span = float(t_hi) - float(t_lo)
        if span <= 0:
            span = 1e-3
        gap = [
            i
            for i in range(lo + 1, hi)
            if rows[i].get("source") != "interlude"
            and float(rows[i].get("timestamp", -1)) < 0
        ]
        g = len(gap)
        if g == 0:
            return
        for rank, idx in enumerate(gap, start=1):
            rows[idx]["timestamp"] = float(t_lo) + span * (rank / (g + 1))
            rows[idx]["source"] = "interpolated"
            rows[idx]["confidence"] = min(float(rows[idx].get("confidence", 0.2)), 0.35)

    if not anchor_indices:
        tick = 0
        for idx in range(n):
            if rows[idx].get("source") == "interlude":
                continue
            rows[idx]["timestamp"] = step * tick
            tick += 1
            rows[idx]["source"] = "interpolated"
            rows[idx]["confidence"] = min(float(rows[idx].get("confidence", 0.2)), 0.35)
        return

    fa = anchor_indices[0]
    la = anchor_indices[-1]

    count_before = 0
    for idx in range(fa - 1, -1, -1):
        if rows[idx].get("source") == "interlude":
            continue
        if float(rows[idx].get("timestamp", -1)) >= 0:
            continue
        count_before += 1
        rows[idx]["timestamp"] = max(0.0, float(rows[fa].get("timestamp", 0.0)) - step * count_before)
        rows[idx]["source"] = "interpolated"
        rows[idx]["confidence"] = min(float(rows[idx].get("confidence", 0.2)), 0.35)

    for gx in range(len(anchor_indices) - 1):
        lo = anchor_indices[gx]
        hi = anchor_indices[gx + 1]
        _fill_between(lo, hi, float(rows[lo]["timestamp"]), float(rows[hi]["timestamp"]))

    count_after = 0
    for idx in range(la + 1, n):
        if rows[idx].get("source") == "interlude":
            continue
        if float(rows[idx].get("timestamp", -1)) >= 0:
            continue
        count_after += 1
        rows[idx]["timestamp"] = float(rows[la]["timestamp"]) + step * count_after
        rows[idx]["source"] = "interpolated"
        rows[idx]["confidence"] = min(float(rows[idx].get("confidence", 0.2)), 0.35)


def _repair_large_jump_snap(
    rows: list[dict[str, Any]],
    lines: list[str],
    segments: list[dict[str, Any]],
    seg_texts: list[str],
) -> None:
    """連続するマッチ行の時刻差が異常に大きいとき、間に挟まれた Whisper セグメントへ歌詞行を取り直す。

    単調整列が後続コーラスへ飛んだだけマッチしているケースで、ギャップ内のより早い
    セグメント（_surface が歌詞と一致）へタイムスタンプを寄せる。
    """
    max_gap = float(os.environ.get("UX_MUSIC_SYNC_MAX_LINE_GAP_SECONDS", "42"))
    min_bg = float(os.environ.get("UX_MUSIC_SYNC_REPAIR_JUMP_MIN_BIGRAM", "0.22"))

    match_indices = [
        idx
        for idx, row in enumerate(rows)
        if row.get("source") == "match" and float(row.get("timestamp", -1)) >= 0
    ]

    for prev_idx, cur_idx in zip(match_indices, match_indices[1:]):
        prev_row = rows[prev_idx]
        cur_row = rows[cur_idx]
        ta = float(prev_row.get("timestamp", -1))
        tb = float(cur_row.get("timestamp", -1))
        if ta < 0 or tb - ta <= max_gap:
            continue

        lyric_next = lines[cur_idx].strip()
        candidates: list[tuple[float, float]] = []
        for seg, tx in zip(segments, seg_texts):
            st = float(seg.get("start", -1e9))
            if st <= ta + 0.05:
                continue
            if st >= tb - 0.05:
                continue
            sc = _char_bigram_precision(lyric_next, tx)
            if sc < min_bg:
                continue
            candidates.append((st, sc))

        if not candidates:
            continue
        candidates.sort(key=lambda z: (z[0], -z[1]))
        best_start = candidates[0][0]
        cur_row["timestamp"] = float(best_start)
        cur_row["confidence"] = min(float(cur_row.get("confidence", 0.55)), 0.72)


def align(
    lines: list[str],
    segments: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    seg_texts = [str(s.get("text", "")).strip() for s in segments]
    line_embs = embed_queries(lines)
    seg_embs = embed_passages(seg_texts)
    ranges = _monotone_greedy_ranges(lines, line_embs, seg_embs, seg_texts)

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
        seg_body = seg_texts[a] if 0 <= a < len(seg_texts) else ""
        surface_agree = _char_bigram_precision(text.strip(), seg_body)
        # 「眺め」／「まだ」のように語頭だけズレて単語オーバーラップが潰れるときは、
        # Whisper のセグメント冒頭時刻をそのまま使う。
        if surface_agree >= 0.28 and a < len(segments):
            start_ts = float(segments[a].get("start", picked.get("start", 0.0)))
        else:
            start_ts = float(picked.get("start", ws[0].get("start", 0.0)))

        matched += 1
        word_ov = max(0.0, scored[0][0]) if scored else 0.0
        confidence = float(0.55 + 0.35 * max(word_ov, surface_agree))

        out_lines.append(
            {
                "index": idx,
                "text": text,
                "timestamp": start_ts,
                "confidence": min(0.96, confidence),
                "source": "match",
            }
        )

    _repair_large_jump_snap(out_lines, lines, segments, seg_texts)
    _interpolate_rows(out_lines)

    detected = [
        {"start": s.get("start"), "end": s.get("end"), "text": s.get("text", "")}
        for s in segments
    ]
    return out_lines, detected
