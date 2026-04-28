"""Line↔ASR alignment: embedding-based monotone matching + per-line start times from word timestamps."""

from __future__ import annotations

import os
from collections import Counter
from typing import Any

import numpy as np

from . import phoneme
from .embeddings import cosine_metrics, embed_passages, embed_queries


def _char_bigram_set(text: str, n: int = 2) -> frozenset[str]:
    """文字バイグラムの集合を前計算して、候補比較のたびに再生成しない。"""
    s = text.strip()
    if len(s) < n:
        return frozenset()
    return frozenset(s[i : i + n] for i in range(len(s) - n + 1))


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


def _char_lcs_ratio(query: str, passage: str) -> float:
    """文字列の最長共通部分列比率。短い歌詞行の近似一致に効く。"""
    q = query.strip()
    p = passage.strip()
    if not q or not p:
        return 0.0
    n = len(q)
    m = len(p)
    prev = [0] * (m + 1)
    for qc in q:
        cur = [0]
        for j, pc in enumerate(p, start=1):
            if qc == pc:
                cur.append(prev[j - 1] + 1)
            else:
                cur.append(max(cur[-1], prev[j]))
        prev = cur
    return prev[-1] / max(1, n)


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
    seg_starts: list[float] | None = None,
    repeat_counts: dict[str, int] | None = None,
    seg_bigrams: list[frozenset[str]] | None = None,
) -> list[tuple[int, int]]:
    """Each non-interlude line maps to one segment index range [a,b]; monotone increasing."""
    n = len(lines)
    m = len(seg_embs)
    out: list[tuple[int, int]] = [(-1, -1)] * n
    j = 0
    lookahead = int(os.environ.get("UX_MUSIC_SYNC_MONOTONE_LOOKAHEAD_SEGMENTS", "32"))
    max_windows = int(os.environ.get("UX_MUSIC_SYNC_MONOTONE_MAX_WINDOWS", "3"))
    refine_topk = int(os.environ.get("UX_MUSIC_SYNC_MONOTONE_REFINEMENT_TOPK", "4"))
    fallback_min = float(os.environ.get("UX_MUSIC_SYNC_MONOTONE_FALLBACK_MIN_SCORE", "0.22"))
    repeat_expected_step = float(os.environ.get("UX_MUSIC_SYNC_REPEAT_EXPECTED_STEP_SECONDS", "3.6"))
    repeat_time_weight = float(os.environ.get("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.035"))
    repeat_step_tolerance = float(os.environ.get("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "1.2"))
    prev_start: float | None = None
    for i in range(n):
        if phoneme.is_interlude(lines[i]):
            continue
        if j >= m:
            out[i] = (m - 1, m - 1) if m else (-1, -1)
            continue
        best_k = j
        best_s = -2.0
        li = lines[i].strip()
        li_bigrams = _char_bigram_set(li)
        w_emb = float(os.environ.get("UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT", "0.52"))
        backtrack = int(os.environ.get("UX_MUSIC_SYNC_MONOTONE_BACKTRACK_SEGMENTS", "6"))
        w_emb = max(0.0, min(1.0, w_emb))
        w_bg = 1.0 - w_emb
        start_k = max(0, j - max(0, backtrack))
        search_lo = start_k
        search_hi = min(m, j + max(0, lookahead))

        def _score_window(lo: int, hi: int) -> tuple[int, float]:
            best_idx = lo
            best_score = -2.0
            if lo >= hi:
                return best_idx, best_score
            top: list[tuple[float, int, float]] = []
            for k in range(lo, hi):
                c = cosine_metrics(line_embs[i], seg_embs[k])
                if seg_bigrams is not None and k < len(seg_bigrams):
                    bigram = len(li_bigrams & seg_bigrams[k]) / max(1, len(li_bigrams))
                elif k < len(seg_texts):
                    bigram = _char_bigram_precision(li, seg_texts[k])
                else:
                    bigram = 0.0
                cheap = w_emb * float(c) + w_bg * float(bigram)
                if len(top) < max(1, refine_topk):
                    top.append((cheap, k, bigram))
                    top.sort(key=lambda z: z[0], reverse=True)
                elif cheap > top[-1][0]:
                    top[-1] = (cheap, k, bigram)
                    top.sort(key=lambda z: z[0], reverse=True)

            for _, k, bigram in top:
                c = cosine_metrics(line_embs[i], seg_embs[k])
                if k < len(seg_texts):
                    lcs = _char_lcs_ratio(li, seg_texts[k])
                    g = max(bigram, lcs)
                else:
                    g = bigram
                # ASR と歌詞の字面一致はコサインだけより先行語誤認に強い。
                # 文字の共通部分も拾って、繰り返しフレーズの早い出現を落としにくくする。
                s = w_emb * float(c) + w_bg * float(g)
                if (
                    seg_starts is not None
                    and k < len(seg_starts)
                    and prev_start is not None
                    and repeat_counts is not None
                    and repeat_counts.get(li, 0) > 1
                ):
                    start_ts = float(seg_starts[k])
                    gap = start_ts - prev_start
                    if gap >= 0:
                        time_gap = abs(gap - repeat_expected_step)
                    else:
                        time_gap = abs(gap) + repeat_expected_step
                    excess = max(0.0, time_gap - repeat_step_tolerance)
                    s -= repeat_time_weight * excess
                if s > best_score:
                    best_score = s
                    best_idx = k
            return best_idx, best_score

        # 近い窓から順に見て、十分なスコアが出た時点で止める。
        # 遠い繰り返しへ吸われるのを抑えつつ、必要なら少し先まで広げる。
        overall_best_k = j
        overall_best_s = -2.0
        windows = 0
        while search_lo < m and windows < max(1, max_windows):
            best_k, best_s = _score_window(search_lo, min(search_hi, m))
            if best_s > overall_best_s:
                overall_best_s = best_s
                overall_best_k = best_k
            windows += 1
            if best_s >= fallback_min:
                break
            if search_hi >= m:
                break
            search_lo = search_hi
            search_hi = min(m, search_hi + max(1, lookahead))
        if seg_starts is not None and overall_best_k < len(seg_starts):
            prev_start = float(seg_starts[overall_best_k])
        out[i] = (overall_best_k, overall_best_k)
        j = overall_best_k + 1
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


def _enforce_monotone_progress(rows: list[dict[str, Any]]) -> None:
    """match 行が前行より大きく巻き戻るのを防ぐ。"""
    min_step = float(os.environ.get("UX_MUSIC_SYNC_MONOTONE_CLAMP_STEP_SECONDS", "2.0"))
    tolerance = float(os.environ.get("UX_MUSIC_SYNC_MONOTONE_CLAMP_TOLERANCE_SECONDS", "0.25"))

    last_ts = None
    for row in rows:
        if row.get("source") == "interlude":
            continue
        ts = float(row.get("timestamp", -1))
        if ts < 0:
            continue
        if last_ts is not None and ts + tolerance < last_ts:
            ts = last_ts + min_step
            row["timestamp"] = ts
            row["confidence"] = min(float(row.get("confidence", 0.55)), 0.72)
        last_ts = ts


def _repair_flat_match_runs(rows: list[dict[str, Any]]) -> None:
    """同じ時刻に張り付いた match 連鎖を、前後のアンカー間でほどく。

    何行も同一タイムスタンプに固まると、再生側では 1 行目以外が全部同じ場所で
    点灯してしまう。大ジャンプ修復では拾えないため、連続する match の平坦な塊を
    線形に開く。
    """
    flat_eps = float(os.environ.get("UX_MUSIC_SYNC_FLAT_MATCH_EPS_SECONDS", "0.75"))
    min_run = int(os.environ.get("UX_MUSIC_SYNC_FLAT_MATCH_MIN_RUN", "3"))
    step = float(os.environ.get("UX_MUSIC_SYNC_INTERPOLATE_STEP_SECONDS", "2.5"))

    def _is_valid(i: int) -> bool:
        return rows[i].get("source") != "interlude" and float(rows[i].get("timestamp", -1)) >= 0

    def _find_prev_anchor(start: int) -> int | None:
        for i in range(start - 1, -1, -1):
            if _is_valid(i):
                return i
        return None

    def _find_next_anchor(start: int) -> int | None:
        for i in range(start, len(rows)):
            if _is_valid(i):
                return i
        return None

    i = 0
    n = len(rows)
    while i < n:
        if rows[i].get("source") != "match" or float(rows[i].get("timestamp", -1)) < 0:
            i += 1
            continue

        j = i + 1
        base = float(rows[i].get("timestamp", -1))
        while j < n and rows[j].get("source") == "match" and float(rows[j].get("timestamp", -1)) >= 0:
            if abs(float(rows[j].get("timestamp", -1)) - base) > flat_eps:
                break
            j += 1

        run_len = j - i
        if run_len < min_run:
            i += 1
            continue

        left_idx = _find_prev_anchor(i)
        right_idx = _find_next_anchor(j)
        if left_idx is not None and right_idx is not None:
            left_t = float(rows[left_idx].get("timestamp", 0.0))
            right_t = float(rows[right_idx].get("timestamp", left_t))
            if right_t > left_t + 1e-6:
                span = right_t - left_t
                for rank, idx in enumerate(range(i, j), start=1):
                    rows[idx]["timestamp"] = left_t + span * (rank / (run_len + 1))
                    rows[idx]["confidence"] = min(float(rows[idx].get("confidence", 0.55)), 0.72)
                i = j
                continue

        if left_idx is not None:
            left_t = float(rows[left_idx].get("timestamp", 0.0))
            for rank, idx in enumerate(range(i, j), start=1):
                rows[idx]["timestamp"] = left_t + step * rank
                rows[idx]["confidence"] = min(float(rows[idx].get("confidence", 0.55)), 0.72)
            i = j
            continue

        if right_idx is not None:
            right_t = float(rows[right_idx].get("timestamp", 0.0))
            for rank, idx in enumerate(reversed(range(i, j)), start=1):
                rows[idx]["timestamp"] = max(0.0, right_t - step * rank)
                rows[idx]["confidence"] = min(float(rows[idx].get("confidence", 0.55)), 0.72)
            i = j
            continue

        i = j


def align(
    lines: list[str],
    segments: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    seg_texts = [str(s.get("text", "")).strip() for s in segments]
    seg_starts = [float(s.get("start", -1e9)) for s in segments]
    repeat_counts = Counter(str(line).strip() for line in lines if not phoneme.is_interlude(line))
    seg_bigrams = [_char_bigram_set(t) for t in seg_texts]
    line_embs = embed_queries(lines)
    seg_embs = embed_passages(seg_texts)
    ranges = _monotone_greedy_ranges(lines, line_embs, seg_embs, seg_texts, seg_starts, repeat_counts, seg_bigrams)

    words_by_segment: dict[int, list[dict[str, Any]]] = {}
    for si, seg in enumerate(segments):
        for w in seg.get("words") or []:
            ww = dict(w)
            ww["segment_index"] = si
            words_by_segment.setdefault(si, []).append(ww)
    line_phonemes: dict[str, list[str]] = {}
    word_phonemes: dict[str, list[str]] = {}
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
        if a < 0 or not words_by_segment:
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

        ws: list[dict[str, Any]] = []
        for si in range(a, b + 1):
            ws.extend(words_by_segment.get(si, ()))
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

        if text in line_phonemes:
            line_p = line_phonemes[text]
        else:
            _line_lang, line_p = phoneme.phoneme_tokens(text)
            line_phonemes[text] = line_p

        scored: list[tuple[float, dict[str, Any]]] = []
        for w in ws:
            tok = str(w.get("word", w.get("text", ""))).strip()
            if not tok:
                continue
            if tok in word_phonemes:
                wp = word_phonemes[tok]
            else:
                _word_lang, wp = phoneme.phoneme_tokens(tok)
                word_phonemes[tok] = wp
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
    _enforce_monotone_progress(out_lines)
    _interpolate_rows(out_lines)

    detected = [
        {"start": s.get("start"), "end": s.get("end"), "text": s.get("text", "")}
        for s in segments
    ]
    return out_lines, detected
