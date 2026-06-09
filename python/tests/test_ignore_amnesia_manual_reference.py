"""IGNORE/アムネシア の手動調整 LRC（manualversion.lrc）を参照した検証。

## 見てから直すサイクル（推奨）

1. **ずれ一覧を出す**（`-s` で標準出力に表が出ます）::

       UX_MUSIC_IGNORE_INTEGRATION=1 \\
         pytest tests/test_ignore_amnesia_manual_reference.py::test_amnesia_auto_sync_vs_manual_lrc_metrics -v -s

2. **上位のずれ行**（`|Δ|` が大きい順）と「予測が遅い／早い」を確認する。

3. **ノブを一回だけ変えて差分比較**する（例）::

       UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT=0.45   # 字面バイグラム寄り
       UX_MUSIC_SYNC_MAX_LINE_GAP_SECONDS=38       # ジャンプ修復の閾値

4. **JSON で記録**（任意）::

       UX_MUSIC_SYNC_REPORT_JSON=/tmp/amnesia-sync-report.json ...

手動タイムスタンプは Bluetooth 等で約 ±500ms のブレがある前提とし、
``timing_mae_after_tolerance_seconds`` を主な改善指標にするとよい。
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from amnesia_manual_assets import resolve_manual_reference_lrc
from lrc_reference import load_txt_nonempty_lines, reference_times_for_lyrics_txt
from sync_accuracy import (
    format_per_line_report,
    improvement_buckets,
    per_line_timing_rows,
    timing_alignment_metrics,
)


@pytest.fixture
def no_dummy_lyrics_sync(monkeypatch):
    monkeypatch.delenv("UX_MUSIC_LYRICS_SYNC_DUMMY", raising=False)


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _amnesia_paths():
    root = _repo_root()
    d = root / "IGNORE" / "アムネシア"
    flacs = sorted(d.glob("*.flac"))
    lyric = d / "lyrics.txt"
    manual = resolve_manual_reference_lrc(d)
    return root, d, flacs[0] if flacs else None, lyric, manual


def _amnesia_assets_ready() -> bool:
    _, _, flac, lyric, manual = _amnesia_paths()
    return flac is not None and lyric.is_file() and manual is not None


@pytest.mark.skipif(
    not _amnesia_assets_ready(),
    reason="IGNORE/アムネシア に lyrics.txt・flac・manualversion.lrc が揃っていません",
)
def test_amnesia_manual_lrc_pairs_lyrics_txt():
    """手動 LRC と lyrics.txt が 36 行一致し、参照時刻が読み込めること。"""
    _root, _d, _f, lyric, manual = _amnesia_paths()
    assert manual is not None
    times = reference_times_for_lyrics_txt(lyric, manual)
    assert len(times) == 36
    # 「眺めていた花が咲いた」1 行目（サビ先頭）
    assert abs(times[8] - 46.99) < 0.02


@pytest.mark.heavy
@pytest.mark.skipif(
    os.environ.get("UX_MUSIC_IGNORE_INTEGRATION", "").strip().lower() not in {"1", "true", "yes"},
    reason="UX_MUSIC_IGNORE_INTEGRATION=1 のときだけフルパイプラインを実行します",
)
def test_amnesia_auto_sync_vs_manual_lrc_metrics(no_dummy_lyrics_sync, monkeypatch):
    """自動同期の行時刻と手動 LRC の MAE（目安）を算出する。"""
    _root, _d, flac, lyric, manual = _amnesia_paths()
    if not flac or not lyric.is_file() or manual is None:
        pytest.skip("アムネシアアセット不完全")

    ref_times = reference_times_for_lyrics_txt(lyric, manual)
    lyric_lines = load_txt_nonempty_lines(lyric)

    whisper = os.environ.get("UX_MUSIC_IGNORE_TEST_WHISPER_MODEL", "base").strip() or "base"
    monkeypatch.setenv("UX_MUSIC_WHISPER_MODEL", whisper)

    from lyrics_sync.pipeline import run_pipeline

    result = run_pipeline(
        {"songPath": str(flac), "lines": lyric_lines, "whisperModel": whisper},
        emit=None,
    )
    assert result.get("success") is True, result.get("error", result)

    tol = float(os.environ.get("UX_MUSIC_SYNC_MANUAL_TOLERANCE_SECONDS", "0.5"))
    m = timing_alignment_metrics(result["lines"], ref_times, manual_tolerance_seconds=tol)
    assert m["valid"] is True

    manual_name = manual.name
    print(
        f"\n[アムネシア vs {manual_name}] tol={tol:.3f}s "
        f"MAE(raw)={m['timing_mae_seconds']:.3f}s "
        f"MAE(after_tol)={m['timing_mae_after_tolerance_seconds']:.3f}s "
        f"median_abs={m['timing_median_abs_seconds']:.3f}s "
        f"max={m['timing_max_abs_seconds']:.3f}s "
        f"within_tol:{m['fraction_within_manual_tolerance']:.1%} "
        f"<=2s:{m['fraction_within_2_0s']:.1%} "
        f"match:{m['source_match_fraction']:.1%}"
    )

    top_n = int(os.environ.get("UX_MUSIC_SYNC_REPORT_TOP_N", "15"))
    per_line = per_line_timing_rows(
        result["lines"], ref_times, lyric_lines, manual_tolerance_seconds=tol
    )
    bk = improvement_buckets(per_line)
    print("\n誤差帯（絶対値・行ごとにどれか一つ）:", bk)
    print()
    print(format_per_line_report(per_line, top_n=top_n, manual_tolerance_seconds=tol))

    json_path = os.environ.get("UX_MUSIC_SYNC_REPORT_JSON", "").strip()
    if json_path != "":
        payload = {
            "manual_reference_lrc": manual_name,
            "metrics": m,
            "buckets": bk,
            "per_line": per_line,
            "env_snapshot": {
                "UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT": os.environ.get(
                    "UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT", ""
                ),
                "UX_MUSIC_SYNC_MAX_LINE_GAP_SECONDS": os.environ.get(
                    "UX_MUSIC_SYNC_MAX_LINE_GAP_SECONDS", ""
                ),
                "UX_MUSIC_IGNORE_TEST_WHISPER_MODEL": os.environ.get(
                    "UX_MUSIC_IGNORE_TEST_WHISPER_MODEL", ""
                ),
            },
        }
        Path(json_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nJSON レポートを書き込みました: {json_path}")

    lim = os.environ.get("UX_MUSIC_SYNC_ASSERT_MAX_MAE_SECONDS", "").strip()
    if lim != "":
        assert m["timing_mae_seconds"] <= float(lim)

    lim_adj = os.environ.get("UX_MUSIC_SYNC_ASSERT_MAX_MAE_AFTER_TOLERANCE_SECONDS", "").strip()
    if lim_adj != "":
        assert m["timing_mae_after_tolerance_seconds"] <= float(lim_adj)
