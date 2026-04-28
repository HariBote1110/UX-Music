"""IGNORE/アムネシア の手動参照 LRC ファイル名（旧タイポ版との互換）。"""

from __future__ import annotations

from pathlib import Path


def resolve_manual_reference_lrc(track_dir: Path) -> Path | None:
    """``manualversion.lrc`` を優先し、無ければ ``manualverison.lrc`` を返す。"""
    for name in ("manualversion.lrc", "manualverison.lrc"):
        p = track_dir / name
        if p.is_file():
            return p
    return None
