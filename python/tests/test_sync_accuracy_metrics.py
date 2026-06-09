"""sync_accuracy の単体試験。"""

from __future__ import annotations

import pytest

from sync_accuracy import (
    format_per_line_report,
    improvement_buckets,
    per_line_timing_rows,
    timing_alignment_metrics,
)


def test_timing_mae_after_tolerance_zeros_small_errors():
    pred = [{"timestamp": 10.6, "source": "match"}]
    ref = [10.0]
    m = timing_alignment_metrics(pred, ref, manual_tolerance_seconds=0.5)
    assert m["valid"] is True
    assert m["timing_mae_seconds"] == pytest.approx(0.6)
    assert m["timing_mae_after_tolerance_seconds"] == pytest.approx(0.1)


def test_fraction_within_manual_tolerance():
    pred = [{"timestamp": 10.0, "source": "match"}, {"timestamp": 11.0, "source": "match"}]
    ref = [10.0, 11.6]
    m = timing_alignment_metrics(pred, ref, manual_tolerance_seconds=0.5)
    assert m["fraction_within_manual_tolerance"] == 0.5


def test_per_line_timing_rows_and_buckets():
    pred = [
        {"timestamp": 100.0, "source": "match"},
        {"timestamp": 11.45, "source": "match"},
    ]
    ref = [10.0, 11.0]
    lyrics = ["長い歌詞行のダミー", "b"]
    rows = per_line_timing_rows(pred, ref, lyrics, manual_tolerance_seconds=0.5)
    assert rows[0]["abs_delta_seconds"] == pytest.approx(90.0)
    assert rows[1]["within_tolerance"] is True
    bk = improvement_buckets(rows)
    assert bk["abs_delta_ge_90s"] == 1
    assert bk["abs_delta_lt_5s"] == 1


def test_format_per_line_report_contains_header():
    rows = [
        {
            "index_1based": 1,
            "text": "hello",
            "pred_seconds": 0.0,
            "ref_seconds": 10.0,
            "signed_delta_seconds": -10.0,
            "abs_delta_seconds": 10.0,
            "residual_after_tolerance_seconds": 9.5,
            "within_tolerance": False,
            "source": "match",
        }
    ]
    s = format_per_line_report(rows, top_n=5, manual_tolerance_seconds=0.5)
    assert "|Δ|" in s
    assert "hello" in s
