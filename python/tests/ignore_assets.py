"""IGNORE 直下のユーザー提供アセットを解決するヘルパー（リポジトリルート基準）。"""

from __future__ import annotations

from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def ignore_directory() -> Path:
    return repo_root() / "IGNORE"


def lyrics_txt_path() -> Path:
    return ignore_directory() / "lyrics.txt"


def find_ignore_flac() -> Path | None:
    directory = ignore_directory()
    if not directory.is_dir():
        return None
    for pattern in ("*.flac", "*.FLAC"):
        matches = sorted(directory.glob(pattern))
        if matches:
            return matches[0]
    return None


def load_lyrics_non_empty_lines(encoding: str = "utf-8") -> list[str]:
    path = lyrics_txt_path()
    text = path.read_text(encoding=encoding)
    lines: list[str] = []
    for raw in text.splitlines():
        s = raw.strip("\ufeff").rstrip("\n\r")
        if s.strip() == "":
            continue
        lines.append(s)
    return lines


def integration_env_enabled() -> bool:
    import os

    return os.environ.get("UX_MUSIC_IGNORE_INTEGRATION", "").strip().lower() in {
        "1",
        "true",
        "yes",
    }
