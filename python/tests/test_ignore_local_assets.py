"""IGNORE 直下の lyrics.txt と FLAC が揃っているときに走る軽量テスト（モデル不要）。"""

from __future__ import annotations

import pytest

from ignore_assets import (
    find_ignore_flac,
    ignore_directory,
    load_lyrics_non_empty_lines,
    lyrics_txt_path,
)


@pytest.mark.skipif(
    not lyrics_txt_path().is_file(),
    reason="IGNORE/lyrics.txt がありません（ローカル用アセット）",
)
def test_ignore_lyrics_utf8_and_key_phrase():
    lines = load_lyrics_non_empty_lines()
    assert len(lines) >= 10
    blob = "\n".join(lines)
    assert "眺めていた花が咲いた" in blob


@pytest.mark.skipif(
    not find_ignore_flac(),
    reason="IGNORE 内に .flac がありません（ローカル用アセット）",
)
def test_ignore_flac_readable():
    try:
        import soundfile as sf
    except ImportError:
        pytest.skip("soundfile が未インストール")

    path = find_ignore_flac()
    assert path is not None
    info = sf.info(str(path))
    assert info.samplerate >= 8000
    assert info.frames > 0


def test_ignore_directory_documented():
    """IGNORE が無い環境でも失敗にしない（CI 向け）。"""
    d = ignore_directory()
    if not d.is_dir():
        pytest.skip("IGNORE ディレクトリがありません")
