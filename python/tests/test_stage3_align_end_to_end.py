"""``stage3_align.align`` の端から端までの試験。

個々の修復関数は ``test_stage3_large_jump_repair`` が単体で叩いているが、
``align`` を通した並び（大ジャンプ → 孤立末尾 → 繰り返し末尾 → 前方ドリフト →
単調化 → 繰り返し末尾 → 補間）は誰も実行していなかった。修復同士が打ち消し合う
事故を拾えるよう、最終的な行の時刻と index をここで固定する。

重い依存は使わない。埋め込みは ``embeddings`` の offline fallback、音素も
pyopenjtalk 無しの文字列フォールバックへ落ちるため、日本語行だけを使う。
"""

from __future__ import annotations

from typing import Any

import pytest

from lyrics_sync import stage3_align


def _segment(start: float, end: float, text: str) -> dict[str, Any]:
    """1 語ぶんの word timestamp を持つ Whisper セグメント相当。"""
    return {
        "start": start,
        "end": end,
        "text": text,
        "words": [{"word": text, "start": start, "end": end}],
    }


def test_align_maps_lines_in_order_and_marks_interlude():
    lines = ["朝の光が差す", "[間奏]", "君の名を呼ぶ", "遠く響く声"]
    segments = [
        _segment(1.0, 4.0, "朝の光が差す"),
        _segment(5.0, 8.0, "君の名を呼ぶ"),
        _segment(9.0, 12.0, "遠く響く声"),
    ]

    rows, detected = stage3_align.align(lines, segments)

    assert [row["index"] for row in rows] == [0, 1, 2, 3]
    assert [row["text"] for row in rows] == lines
    assert [row["source"] for row in rows] == ["match", "interlude", "match", "match"]
    assert [row["timestamp"] for row in rows] == [1.0, -1.0, 5.0, 9.0]
    # 間奏行は補間の対象外なので、後段の ``_interpolate_rows`` でも -1.0 のまま。
    assert rows[1]["confidence"] == pytest.approx(0.25)
    assert [d["start"] for d in detected] == [1.0, 5.0, 9.0]


def test_align_snaps_large_jump_back_to_intermediate_segment():
    """後半の完全一致へ飛んだ行を、ギャップ内の聞き取り違いセグメントへ戻す。"""
    walk = "夜明けの街を歩く"
    chorus = "遠く響く声が消える"
    garbled = "とおくひびく声が消える"
    lines = [walk, chorus]
    segments = [
        _segment(2.0, 5.0, walk),
        _segment(20.0, 24.0, garbled),
        _segment(100.0, 104.0, chorus),
    ]

    rows, _ = stage3_align.align(lines, segments)

    assert rows[0]["timestamp"] == 2.0
    assert rows[0]["confidence"] > 0.72
    # 単調整列は 100.0 の完全一致を選ぶが、2.0 との差が 42 秒を超えるため
    # ``_repair_large_jump_snap`` が 20.0 の聞き取り違いセグメントへ引き戻す。
    assert rows[1]["timestamp"] == 20.0
    assert rows[1]["confidence"] == pytest.approx(0.72)
    assert [row["source"] for row in rows] == ["match", "match"]


def test_align_enforces_monotone_progress_after_the_repair_passes():
    """開始時刻が前後した ASR でも、最終行は必ず前へ進む。"""
    lines = ["朝の光が差す", "君の名を呼ぶ", "遠く響く声"]
    segments = [
        _segment(10.0, 13.0, "朝の光が差す"),
        # Whisper が稀に返す時刻の逆転（index は昇順だが start が巻き戻る）。
        _segment(5.0, 8.0, "君の名を呼ぶ"),
        _segment(20.0, 23.0, "遠く響く声"),
    ]

    rows, _ = stage3_align.align(lines, segments)

    timestamps = [row["timestamp"] for row in rows]
    assert timestamps == sorted(timestamps)
    assert timestamps[0] == 10.0
    # 5.0 のままにはせず、``UX_MUSIC_SYNC_MONOTONE_CLAMP_STEP_SECONDS`` 既定の
    # +2.0 秒だけ前行から進める。
    assert timestamps[1] == pytest.approx(12.0)
    assert rows[1]["confidence"] == pytest.approx(0.72)
    assert timestamps[2] == 20.0
