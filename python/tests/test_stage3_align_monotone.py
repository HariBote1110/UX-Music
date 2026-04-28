"""Unit tests for `_monotone_greedy_ranges` / `_pick_start_word`（埋め込みは行列で差し替え）。"""

from __future__ import annotations

import numpy as np
import pytest

from lyrics_sync import stage3_align


def test_monotone_first_segment_wins_on_embedding_tie():
    """同類似度だと先に見つかったセグメントを採用する（> のため後勝ちにならない）。"""
    lines = ["one", "two"]
    dim = 6
    line_embs = np.zeros((2, dim))
    line_embs[0, 0] = 1.0
    line_embs[1, 1] = 1.0
    m = 4
    seg_embs = np.zeros((m, dim))
    seg_embs[0, 0] = 1.0
    seg_embs[1, 1] = 1.0
    seg_embs[3, 1] = 1.0
    ranges = stage3_align._monotone_greedy_ranges(lines, line_embs, seg_embs)
    assert ranges[0] == (0, 0)
    assert ranges[1][0] == 1


def test_interlude_skips_row_and_does_not_advance_pointer_for_next_line():
    """間奏行は範囲 (-1,-1) のまま。次の歌詞行は直前の非間奏の j から探索が続く。"""
    lines = ["verse", "[間奏]", "chorus"]
    dim = 4
    line_embs = np.zeros((3, dim))
    line_embs[0, 0] = 1.0
    line_embs[2, 2] = 1.0
    m = 5
    seg_embs = np.zeros((m, dim))
    seg_embs[0, 0] = 1.0
    seg_embs[1, 1] = 0.5
    seg_embs[2, 1] = 0.5
    seg_embs[4, 2] = 1.0
    ranges = stage3_align._monotone_greedy_ranges(lines, line_embs, seg_embs)
    assert ranges[0] == (0, 0)
    assert ranges[1] == (-1, -1)
    assert ranges[2][0] == 4


def test_pick_start_word_falls_back_to_best_scoring_early_word(monkeypatch):
    """閾値未満のみのとき時刻順先頭から最大スコア語へフォールバック（g2p/NLTK に依存しない）。"""

    def stub_tokens(t: str):
        tok = str(t).strip()
        if tok == "zzz":
            return ("en", ["p1"])
        if tok == "yyy":
            return ("en", ["p2"])
        return ("en", [])

    monkeypatch.setattr(stage3_align.phoneme, "phoneme_tokens", stub_tokens)

    line_prefix = ["p1", "p9", "p9"]
    ws = [
        {"word": "zzz", "start": 0.1, "end": 0.2},
        {"word": "yyy", "start": 0.3, "end": 0.4},
    ]
    picked, score = stage3_align._pick_start_word("stub line", "en", line_prefix, ws)
    assert float(picked.get("start", -1.0)) == pytest.approx(0.1)
    assert score >= 0.17


def test_pick_start_word_empty_ws_returns_empty():
    picked, score = stage3_align._pick_start_word("hello", "en", ["h"], [])
    assert picked == {}
    assert score == 0.0

