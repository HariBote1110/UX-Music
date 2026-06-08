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


def test_repair_isolated_gap_tail_snaps_previous_row():
    rows = [
        {"timestamp": 10.0, "source": "match", "confidence": 0.8},
        {"timestamp": 20.0, "source": "match", "confidence": 0.8},
        {"timestamp": 70.0, "source": "match", "confidence": 0.8},
    ]
    lines = ["anchor", "tail line", "next line"]
    segments = [
        {"start": 10.0, "text": "anchor"},
        {"start": 40.0, "text": "tail line"},
        {"start": 60.0, "text": "tail line"},
        {"start": 70.0, "text": "next line"},
    ]
    seg_texts = [str(seg.get("text", "")) for seg in segments]

    stage3_align._repair_isolated_gap_tail(rows, lines, segments, seg_texts)

    assert rows[1]["timestamp"] == 60.0
    assert rows[1]["confidence"] <= 0.72


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


def test_monotone_ranges_allows_small_repeat_rewind(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.5")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_REPEAT_REWIND_LIMIT_SECONDS", "18.0")
    lines = ["anchor", "repeat me", "repeat me"]
    line_embs = np.zeros((3, 2), dtype=float)
    seg_embs = np.zeros((3, 2), dtype=float)
    seg_texts = ["repeat me", "anchor", "repeat me"]
    seg_starts = [10.0, 14.0, 30.0]
    repeat_counts = {"repeat me": 2, "anchor": 1}

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    assert ranges[0] == (1, 1)
    assert ranges[1] == (0, 0)


def test_monotone_ranges_keeps_earlier_repeat_over_exact_late_match(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.5")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_REPEAT_REWIND_LIMIT_SECONDS", "18.0")
    lines = ["anchor", "たとえあしたが見えず不可能だって", "たとえあしたが見えず不可能だって"]
    line_embs = np.zeros((3, 2), dtype=float)
    seg_embs = np.zeros((3, 2), dtype=float)
    seg_texts = ["anchor", "たとえあしたが見えず不可能だって", "たとえあしたが見えず不可能だって"]
    seg_starts = [64.6, 67.2, 160.94]
    repeat_counts = {"anchor": 1, "たとえあしたが見えず不可能だって": 2}

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


def test_monotone_ranges_keeps_first_window_for_repeated_line(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_LOOKAHEAD_SEGMENTS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_MAX_WINDOWS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_BACKTRACK_SEGMENTS", "0")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_REFINEMENT_TOPK", "1")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_REPEAT_REWIND_LIMIT_SECONDS", "18.0")

    lines = ["anchor", "repeat me"]
    seg_texts = ["anchor", "repeat x", "filler", "repeat me"]
    seg_starts = [10.0, 12.0, 16.0, 20.0]
    repeat_counts = {"anchor": 1, "repeat me": 2}
    line_embs = np.zeros((2, 2), dtype=float)
    seg_embs = np.zeros((4, 2), dtype=float)

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


def test_monotone_ranges_stops_rescanning_when_repeat_gap_is_large(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_LOOKAHEAD_SEGMENTS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_MAX_WINDOWS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_BACKTRACK_SEGMENTS", "0")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_REFINEMENT_TOPK", "1")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_RESCAN_MAX_GAP_SECONDS", "3.0")

    lines = ["anchor", "repeat me"]
    seg_texts = ["anchor", "repeat x", "filler", "repeat me"]
    seg_starts = [10.0, 15.0, 18.0, 25.0]
    repeat_counts = {"anchor": 1, "repeat me": 2}
    line_embs = np.zeros((2, 2), dtype=float)
    seg_embs = np.zeros((4, 2), dtype=float)

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


def test_monotone_ranges_does_not_rescan_middle_repeat_line(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_LOOKAHEAD_SEGMENTS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_MAX_WINDOWS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_BACKTRACK_SEGMENTS", "0")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_REFINEMENT_TOPK", "1")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")

    lines = ["anchor", "repeat me", "repeat me"]
    seg_texts = ["anchor", "repeat x", "filler", "repeat me"]
    seg_starts = [10.0, 12.0, 16.0, 20.0]
    repeat_counts = {"anchor": 1, "repeat me": 2}
    line_embs = np.zeros((3, 2), dtype=float)
    seg_embs = np.zeros((4, 2), dtype=float)

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
    assert ranges[2] == (3, 3)


def test_repair_repeated_block_tail_extension_extends_only_tail(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TAIL_EXTENSION_SECONDS", "10.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TAIL_MAX_PREV_GAP_SECONDS", "2.75")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TAIL_MIN_NEXT_GAP_SECONDS", "20.0")

    rows = [
        {"timestamp": 10.0, "source": "match", "confidence": 0.8},
        {"timestamp": 12.0, "source": "match", "confidence": 0.8},
        {"timestamp": 14.0, "source": "match", "confidence": 0.8},
    ]
    lines = ["anchor", "repeat me", "repeat me"]

    stage3_align._repair_repeated_block_tail_extension(rows, lines)

    assert rows[1]["timestamp"] == 12.0
    assert rows[2]["timestamp"] == 22.0


def test_repair_forward_drift_uses_skipped_segments_after_large_jump(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_FORWARD_DRIFT_GAP_SECONDS", "30.0")
    rows = [
        {"timestamp": 20.0, "source": "match", "confidence": 0.8},
        {"timestamp": 140.0, "source": "match", "confidence": 0.8},
        {"timestamp": 142.0, "source": "match", "confidence": 0.8},
    ]
    segments = [
        {"start": 20.0, "text": "anchor"},
        {"start": 44.0, "text": "skipped one"},
        {"start": 52.0, "text": "skipped two"},
        {"start": 140.0, "text": "late repeat"},
    ]

    stage3_align._repair_forward_drift_to_skipped_segments(rows, segments)

    assert rows[1]["timestamp"] == 44.0
    assert rows[1]["confidence"] <= 0.72
    assert rows[2]["timestamp"] == 52.0
    assert rows[2]["confidence"] <= 0.72


def test_repair_forward_drift_starts_from_early_segments(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_FORWARD_DRIFT_GAP_SECONDS", "30.0")
    rows = [
        {"timestamp": 110.0, "source": "match", "confidence": 0.8},
        {"timestamp": 112.0, "source": "match", "confidence": 0.8},
    ]
    segments = [
        {"start": 24.0, "text": "early one"},
        {"start": 31.0, "text": "early two"},
        {"start": 110.0, "text": "late repeat"},
    ]

    stage3_align._repair_forward_drift_to_skipped_segments(rows, segments)

    assert rows[0]["timestamp"] == 24.0
    assert rows[1]["timestamp"] == 31.0
    assert rows[1]["confidence"] <= 0.72
