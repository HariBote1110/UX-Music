"""``stage3_align`` の大ジャンプ修復試験。"""

from __future__ import annotations

import numpy as np

from lyrics_sync import stage3_align


def test_repair_large_jump_snap_targets_next_matched_line():
    rows = [
        {"timestamp": 10.0, "source": "match", "confidence": 0.8},
        {"timestamp": -1.0, "source": "interpolated", "confidence": 0.2},
        {"timestamp": -1.0, "source": "interpolated", "confidence": 0.2},
        {"timestamp": 80.0, "source": "match", "confidence": 0.8},
    ]
    lines = ["まだ届くはずだった", "あいだの行1", "あいだの行2", "眺めていた花が咲いた"]
    segments = [
        {"start": 12.0, "text": "まだ届くはずだった"},
        {"start": 24.0, "text": "眺めていた花が咲いた"},
        {"start": 40.0, "text": "眺めていた花が咲いた まだ届くはずだった"},
    ]
    seg_texts = [str(seg.get("text", "")) for seg in segments]

    stage3_align._repair_large_jump_snap(rows, lines, segments, seg_texts)

    assert rows[3]["timestamp"] == 24.0
    assert rows[3]["confidence"] <= 0.72


def test_enforce_monotone_progress_raises_backwards_rows():
    rows = [
        {"timestamp": 78.52, "source": "match", "confidence": 0.8},
        {"timestamp": 67.22, "source": "match", "confidence": 0.8},
        {"timestamp": 71.5, "source": "match", "confidence": 0.8},
    ]

    stage3_align._enforce_monotone_progress(rows)

    assert rows[1]["timestamp"] == 80.52
    assert rows[1]["confidence"] <= 0.72
    assert rows[2]["timestamp"] == 82.52
    assert rows[2]["confidence"] <= 0.72


def test_monotone_ranges_prefers_closer_repeat_candidate(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.5")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    lines = ["repeat me", "repeat me"]
    line_embs = np.zeros((2, 2), dtype=float)
    seg_embs = np.zeros((3, 2), dtype=float)
    seg_texts = ["repeat me", "repeat me", "repeat me"]
    seg_starts = [10.0, 14.0, 30.0]
    repeat_counts = {"repeat me": 2}

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    assert ranges[0] == (0, 0)
    assert ranges[1] == (1, 1)
