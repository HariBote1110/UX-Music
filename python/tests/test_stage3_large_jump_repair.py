"""``stage3_align`` の大ジャンプ修復試験。"""

from __future__ import annotations

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
