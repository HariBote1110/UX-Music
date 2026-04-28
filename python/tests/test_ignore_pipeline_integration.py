"""
IGNORE の lyrics.txt + *.flac でフルパイプラインを検証する結合テスト。

非常に重いです（Demucs / Whisper / 埋め込み）。既定ではスキップし、
次のように有効化します。

    export UX_MUSIC_IGNORE_INTEGRATION=1
    # 任意: 速いモデル（既定は base）
    export UX_MUSIC_IGNORE_TEST_WHISPER_MODEL=base

    cd リポジトリルート
    PYTHONPATH=python pytest python/tests/test_ignore_pipeline_integration.py -m heavy -v
"""

from __future__ import annotations

import os

import pytest

from ignore_assets import (
    find_ignore_flac,
    integration_env_enabled,
    load_lyrics_non_empty_lines,
    lyrics_txt_path,
)


pytestmark = pytest.mark.heavy


def _skip_if_not_ready():
    if not lyrics_txt_path().is_file():
        pytest.skip("IGNORE/lyrics.txt がありません")
    flac = find_ignore_flac()
    if not flac:
        pytest.skip("IGNORE 内に .flac がありません")
    if not integration_env_enabled():
        pytest.skip(
            "UX_MUSIC_IGNORE_INTEGRATION=1 のときだけ実行します（フルパイプラインは重い）"
        )


@pytest.fixture
def no_lyrics_dummy(monkeypatch):
    monkeypatch.delenv("UX_MUSIC_LYRICS_SYNC_DUMMY", raising=False)


def test_ignore_full_pipeline_amnesia(no_lyrics_dummy, monkeypatch):
    _skip_if_not_ready()

    whisper = os.environ.get("UX_MUSIC_IGNORE_TEST_WHISPER_MODEL", "base").strip() or "base"
    monkeypatch.setenv("UX_MUSIC_WHISPER_MODEL", whisper)

    from lyrics_sync.pipeline import run_pipeline

    lines = load_lyrics_non_empty_lines()
    flac = find_ignore_flac()
    assert flac is not None

    staged: list[tuple[str, float]] = []

    def emit(stage: str, pct: float) -> None:
        staged.append((stage, pct))

    result = run_pipeline(
        {"songPath": str(flac), "lines": lines, "whisperModel": whisper},
        emit=emit,
    )

    assert result.get("success") is True, result.get("error", result)
    assert isinstance(result.get("lines"), list)
    matched = sum(1 for row in result["lines"] if row.get("source") == "match")
    assert matched >= 1, "少なくとも1行は Whisper 単語タイムスタンプへマッチが必要"

    keyed = [
        row
        for row in result["lines"]
        if "眺めていた花が咲いた" in str(row.get("text", ""))
    ]
    assert len(keyed) >= 1
    ts = float(keyed[0].get("timestamp", -99.0))
    assert ts >= 0.0
