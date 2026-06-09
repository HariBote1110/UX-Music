"""``stage3_align._interpolate_rows`` の単体試験。"""

from __future__ import annotations

import pytest

from lyrics_sync import stage3_align


def test_interpolate_even_spacing_between_two_anchors():
    rows = [
        {"timestamp": 0.0, "source": "match"},
        {"timestamp": -1.0, "source": "interpolated"},
        {"timestamp": -1.0, "source": "interpolated"},
        {"timestamp": -1.0, "source": "interpolated"},
        {"timestamp": 100.0, "source": "match"},
    ]
    stage3_align._interpolate_rows(rows)
    assert rows[1]["timestamp"] == pytest.approx(100.0 / 4.0)
    assert rows[2]["timestamp"] == pytest.approx(200.0 / 4.0)
    assert rows[3]["timestamp"] == pytest.approx(300.0 / 4.0)


def test_interpolate_tail_steps_use_constant_gap(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_INTERPOLATE_STEP_SECONDS", "3.0")
    rows = [
        {"timestamp": 50.0, "source": "match"},
        {"timestamp": -1.0, "source": "interpolated"},
        {"timestamp": -1.0, "source": "interpolated"},
    ]
    stage3_align._interpolate_rows(rows)
    assert rows[1]["timestamp"] == pytest.approx(53.0)
    assert rows[2]["timestamp"] == pytest.approx(56.0)


def test_interpolate_skips_interlude_rows():
    rows = [
        {"timestamp": 10.0, "source": "match"},
        {"timestamp": -1.0, "source": "interlude"},
        {"timestamp": -1.0, "source": "interpolated"},
        {"timestamp": 40.0, "source": "match"},
    ]
    stage3_align._interpolate_rows(rows)
    assert rows[1]["timestamp"] == pytest.approx(-1.0)
    assert rows[2]["timestamp"] == pytest.approx(25.0)


def test_interpolate_no_anchor_assigns_sequential(monkeypatch):
    monkeypatch.setenv("UX_MUSIC_SYNC_INTERPOLATE_STEP_SECONDS", "2.0")
    rows = [
        {"timestamp": -1.0, "source": "interpolated"},
        {"timestamp": -1.0, "source": "interpolated"},
    ]
    stage3_align._interpolate_rows(rows)
    assert rows[0]["timestamp"] == pytest.approx(0.0)
    assert rows[1]["timestamp"] == pytest.approx(2.0)
