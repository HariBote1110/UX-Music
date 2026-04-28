"""Unit tests for segment↔line greedy matching (instrumental-gap robustness)."""

from __future__ import annotations

import numpy as np

from lyrics_sync import stage3_align


def test_segment_word_bonus_prefers_dense_words_over_long_sparse():
    seg_dense = {
        "start": 0.0,
        "end": 4.0,
        "text": "a b c d e",
        "words": [{"word": "a"}, {"word": "b"}, {"word": "c"}, {"word": "d"}, {"word": "e"}],
    }
    seg_sparse = {
        "start": 0.0,
        "end": 15.0,
        "text": "hum",
        "words": [{"word": "hum"}],
    }
    assert stage3_align._segment_word_bonus(seg_dense) > stage3_align._segment_word_bonus(seg_sparse)


def test_empty_words_segment_gets_low_bonus():
    seg = {"start": 0.0, "end": 8.0, "text": "", "words": []}
    assert stage3_align._segment_word_bonus(seg) < 0.25


def test_monotone_prefers_later_segment_on_tie():
    """When two segments have equal adjusted score, pick the later one in time."""
    lines = ["one", "two"]
    dim = 8
    line_embs = np.zeros((2, dim))
    line_embs[0, 0] = 1.0
    line_embs[1, 1] = 1.0
    m = 4
    seg_embs = np.zeros((m, dim))
    seg_embs[0, 0] = 1.0
    # Line "two" could match seg1 or seg3 equally on raw cosine; should pick seg3 (later start).
    seg_embs[1, 1] = 1.0
    seg_embs[3, 1] = 1.0
    segments = [
        {"start": 0.0, "end": 1.0, "text": "x", "words": [{"word": "x"}]},
        {"start": 1.0, "end": 2.0, "text": "a", "words": [{"word": "a"}]},
        {"start": 2.0, "end": 3.0, "text": "b", "words": [{"word": "b"}]},
        {"start": 10.0, "end": 11.0, "text": "a", "words": [{"word": "a"}]},
    ]
    ranges = stage3_align._monotone_greedy_ranges(lines, line_embs, seg_embs, segments)
    assert ranges[0][0] == 0
    assert ranges[1][0] == 3


def test_weak_match_jumps_after_long_instrumental_zone():
    """After a long vocal block, a weak embedding match retries from later audio."""
    lines = ["verse", "[間奏]", "chorus"]
    dim = 12
    line_embs = np.zeros((3, dim))
    line_embs[0, 0] = 1.0
    line_embs[2, 1] = 1.0
    m = 20
    seg_embs = np.zeros((m, dim))
    # First line matches seg 0
    seg_embs[0, 0] = 1.0
    # Instrumental-like middle: same dim1 component as chorus but weak via word_bonus
    for k in range(1, 15):
        seg_embs[k, 1] = 0.95
    # True chorus match (slightly better than junk when bonus applied)
    seg_embs[16, 1] = 1.0
    segments = []
    for k in range(m):
        if 1 <= k <= 14:
            words = [{"word": "hum"}] if k % 2 == 0 else [{"word": "la"}]
            dur = 3.0
            st = float(k * 2.0)
            segments.append(
                {
                    "start": st,
                    "end": st + dur,
                    "text": "xxx",
                    "words": words,
                }
            )
        else:
            st = float(k * 2.0)
            segments.append(
                {
                    "start": st,
                    "end": st + 1.2,
                    "text": "chorus text here",
                    "words": [{"word": "c"}, {"word": "h"}, {"word": "o"}],
                }
            )
    ranges = stage3_align._monotone_greedy_ranges(lines, line_embs, seg_embs, segments)
    assert ranges[0][0] == 0
    assert ranges[2][0] >= 15, f"expected jump past instrumental tail, got {ranges[2]}"
