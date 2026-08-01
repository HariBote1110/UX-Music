"""``stage3_align`` の大ジャンプ修復試験。"""

from __future__ import annotations

import pytest

from lyrics_sync import embeddings, stage3_align

_FALLBACK = embeddings._FallbackModel()


def _encode(texts: list[str], *, prefix: str):
    """本番 ``embeddings._encode`` と同じ前処理で決定論的なベクトルを作る。

    ゼロ行列を渡すと ``cosine_metrics`` が常に 0 になり、照合の主信号が消えてしまう。
    オフラインでも動く fallback モデルを使って、区別のつく埋め込みで検証する。
    """
    return _FALLBACK.encode(
        [f"{prefix}: {(t or '').strip()}" for t in texts],
        convert_to_numpy=True,
        show_progress_bar=False,
        normalize_embeddings=True,
    )


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
    assert rows[3]["confidence"] == pytest.approx(0.72)


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
    assert rows[1]["confidence"] == pytest.approx(0.72)


def test_enforce_monotone_progress_raises_backwards_rows():
    rows = [
        {"timestamp": 78.52, "source": "match", "confidence": 0.8},
        {"timestamp": 67.22, "source": "match", "confidence": 0.8},
        {"timestamp": 71.5, "source": "match", "confidence": 0.8},
    ]

    stage3_align._enforce_monotone_progress(rows)

    assert rows[1]["timestamp"] == 80.52
    assert rows[1]["confidence"] == pytest.approx(0.72)
    assert rows[2]["timestamp"] == 82.52
    assert rows[2]["confidence"] == pytest.approx(0.72)


def test_repair_confidence_clamp_never_raises_an_already_low_confidence():
    """0.72 は上限クランプであって代入ではない（``min(..., 0.72)`` の下側を固定する）。"""
    rows = [
        {"timestamp": 78.52, "source": "match", "confidence": 0.8},
        {"timestamp": 67.22, "source": "match", "confidence": 0.31},
    ]

    stage3_align._enforce_monotone_progress(rows)

    assert rows[1]["timestamp"] == 80.52
    assert rows[1]["confidence"] == pytest.approx(0.31)


def test_monotone_ranges_prefers_closer_repeat_candidate(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.5")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    lines = ["repeat me", "repeat me"]
    # 先頭に無関係なイントロ段を挟み、正解が恒等写像 (i, i) と一致しないようにする。
    seg_texts = ["intro chatter", "repeat me", "repeat me", "repeat me"]
    seg_starts = [2.0, 10.0, 14.0, 30.0]
    repeat_counts = {"repeat me": 2}
    line_embs = _encode(lines, prefix="query")
    seg_embs = _encode(seg_texts, prefix="passage")

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    # 1 行目は無関係なイントロを飛ばして最初の "repeat me" へ。
    assert ranges[0] == (1, 1)
    # 2 行目は 30.0 の遠い繰り返しではなく、直近 14.0 の出現を選ぶ。
    assert ranges[1] == (2, 2)


def test_monotone_ranges_allows_small_repeat_rewind(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.5")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_REPEAT_REWIND_LIMIT_SECONDS", "18.0")
    lines = ["anchor", "repeat me", "repeat me"]
    seg_texts = ["repeat me", "anchor", "repeat me"]
    seg_starts = [10.0, 14.0, 30.0]
    repeat_counts = {"repeat me": 2, "anchor": 1}
    line_embs = _encode(lines, prefix="query")
    seg_embs = _encode(seg_texts, prefix="passage")

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    assert ranges[0] == (1, 1)
    # 小さな巻き戻り（14.0 → 10.0）は許容され、遠い 30.0 へは吸われない。
    assert ranges[1] == (0, 0)


def test_monotone_ranges_keeps_earlier_repeat_over_exact_late_match(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.5")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_REPEAT_REWIND_LIMIT_SECONDS", "18.0")
    chorus = "たとえあしたが見えず不可能だって"
    lines = ["anchor", chorus, chorus]
    seg_texts = ["イントロのざわめき", "anchor", chorus, chorus]
    seg_starts = [60.0, 64.6, 67.2, 160.94]
    repeat_counts = {"anchor": 1, chorus: 2}
    line_embs = _encode(lines, prefix="query")
    seg_embs = _encode(seg_texts, prefix="passage")

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    assert ranges[0] == (1, 1)
    # 完全一致する 160.94 の後半サビではなく、直後 67.2 の早い出現を保つ。
    assert ranges[1] == (2, 2)


def test_monotone_ranges_keeps_first_window_for_repeated_line(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_LOOKAHEAD_SEGMENTS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_MAX_WINDOWS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_BACKTRACK_SEGMENTS", "0")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_REFINEMENT_TOPK", "1")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_REPEAT_REWIND_LIMIT_SECONDS", "18.0")

    lines = ["anchor", "repeat me"]
    seg_texts = ["intro noise", "anchor", "repeat x", "filler", "repeat me"]
    seg_starts = [6.0, 10.0, 12.0, 16.0, 20.0]
    repeat_counts = {"anchor": 1, "repeat me": 2}
    line_embs = _encode(lines, prefix="query")
    seg_embs = _encode(seg_texts, prefix="passage")

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    assert ranges[0] == (1, 1)
    # 最初の窓 [2,4) で十分なスコアが出るので、完全一致の "repeat me"(index 4) までは広げない。
    assert ranges[1] == (2, 2)


def test_monotone_ranges_stops_rescanning_when_repeat_gap_is_large(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_LOOKAHEAD_SEGMENTS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_MAX_WINDOWS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_BACKTRACK_SEGMENTS", "0")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_REFINEMENT_TOPK", "1")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_RESCAN_MAX_GAP_SECONDS", "3.0")

    lines = ["anchor", "repeat me"]
    seg_texts = ["intro noise", "anchor", "repeat x", "filler", "repeat me"]
    seg_starts = [6.0, 10.0, 15.0, 18.0, 25.0]
    repeat_counts = {"anchor": 1, "repeat me": 2}
    line_embs = _encode(lines, prefix="query")
    seg_embs = _encode(seg_texts, prefix="passage")

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    assert ranges[0] == (1, 1)
    assert ranges[1] == (2, 2)


def test_monotone_ranges_does_not_rescan_middle_repeat_line(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_LOOKAHEAD_SEGMENTS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_MAX_WINDOWS", "2")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_BACKTRACK_SEGMENTS", "0")
    monkeypatch.setenv("UX_MUSIC_SYNC_MONOTONE_REFINEMENT_TOPK", "1")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_TIME_WEIGHT", "0.0")
    monkeypatch.setenv("UX_MUSIC_SYNC_REPEAT_STEP_TOLERANCE_SECONDS", "0.0")

    lines = ["anchor", "repeat me", "repeat me"]
    seg_texts = ["intro noise", "anchor", "repeat x", "filler", "repeat me"]
    seg_starts = [6.0, 10.0, 12.0, 16.0, 20.0]
    repeat_counts = {"anchor": 1, "repeat me": 2}
    line_embs = _encode(lines, prefix="query")
    seg_embs = _encode(seg_texts, prefix="passage")

    ranges = stage3_align._monotone_greedy_ranges(
        lines,
        line_embs,
        seg_embs,
        seg_texts,
        seg_starts,
        repeat_counts,
    )

    assert ranges[0] == (1, 1)
    assert ranges[1] == (2, 2)
    # 中間の繰り返し行は再走査されず、末尾行だけが完全一致 index 4 へ進む。
    assert ranges[2] == (4, 4)


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
    assert rows[1]["confidence"] == pytest.approx(0.72)
    assert rows[2]["timestamp"] == 52.0
    assert rows[2]["confidence"] == pytest.approx(0.72)


def test_repair_forward_drift_handles_mid_sized_repeated_chorus_jump_when_tuned(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_FORWARD_DRIFT_GAP_SECONDS", "18.0")
    rows = [
        {"timestamp": 156.4, "source": "match", "confidence": 0.8},
        {"timestamp": 195.74, "source": "match", "confidence": 0.8},
        {"timestamp": 203.54, "source": "match", "confidence": 0.8},
        {"timestamp": 233.52, "source": "match", "confidence": 0.8},
    ]
    segments = [
        {"start": 156.4, "text": "anchor"},
        {"start": 163.0, "text": "early repeated chorus line"},
        {"start": 170.92, "text": "next early line"},
        {"start": 177.22, "text": "next early line two"},
        {"start": 195.74, "text": "late repeat"},
    ]

    stage3_align._repair_forward_drift_to_skipped_segments(rows, segments)

    assert rows[1]["timestamp"] == 163.0
    assert rows[2]["timestamp"] == 170.92
    assert rows[3]["timestamp"] == 177.22
    assert rows[3]["confidence"] == pytest.approx(0.72)


def test_repair_forward_drift_default_ignores_mid_sized_jump():
    rows = [
        {"timestamp": 156.4, "source": "match", "confidence": 0.8},
        {"timestamp": 195.74, "source": "match", "confidence": 0.8},
    ]
    segments = [
        {"start": 156.4, "text": "anchor"},
        {"start": 163.0, "text": "early repeated chorus line"},
        {"start": 195.74, "text": "late repeat"},
    ]

    stage3_align._repair_forward_drift_to_skipped_segments(rows, segments)

    assert rows[1]["timestamp"] == 195.74


def test_repair_forward_drift_stops_when_skipped_segment_text_does_not_match_line(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_FORWARD_DRIFT_GAP_SECONDS", "18.0")
    rows = [
        {"timestamp": 156.4, "source": "match", "confidence": 0.8},
        {"timestamp": 195.74, "source": "match", "confidence": 0.8},
        {"timestamp": 203.54, "source": "match", "confidence": 0.8},
    ]
    lines = [
        "anchor",
        "紅の朝焼けが 焦りの心を宥めてゆく",
        "It never change…",
    ]
    segments = [
        {"start": 156.4, "text": "anchor"},
        {"start": 163.0, "text": "くれないの 当て焼けた 当てりの心を流れてゆく"},
        {"start": 170.92, "text": "少しずつで生きて 明日ですね"},
        {"start": 195.74, "text": "late repeat"},
    ]

    stage3_align._repair_forward_drift_to_skipped_segments(rows, segments, lines)

    assert rows[1]["timestamp"] == 163.0
    assert rows[2]["timestamp"] == 203.54


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
    assert rows[1]["confidence"] == pytest.approx(0.72)
