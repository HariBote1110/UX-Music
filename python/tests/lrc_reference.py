"""参照用 LRC のパース（テスト・精度評価用）。"""

from __future__ import annotations

import re
from pathlib import Path

_LRC_HEAD = re.compile(r"^\s*\[(\d{2}):(\d{2})\.(\d{2,3})\]\s*(.*)$")


def parse_lrc_line_times_and_texts(path: Path | str, encoding: str = "utf-8") -> list[tuple[float, str]]:
    """先頭タイムスタンプと残りテキスト。空行・余分タグ除去後も空なら含めない。"""
    out: list[tuple[float, str]] = []
    for raw in Path(path).read_text(encoding=encoding).splitlines():
        s = raw.strip("\ufeff").strip()
        if not s:
            continue
        m = _LRC_HEAD.match(s)
        if not m:
            continue
        mm_s, ss_s, frac_s, rest = m.groups()
        frac_norm = frac_s.ljust(3, "0")[:3]
        ts = int(mm_s) * 60 + int(ss_s) + int(frac_norm) / 1000.0
        txt = rest.strip()
        txt = re.sub(r"\[\d{2}:\d{2}\.\d{2,3}\]", "", txt).strip()
        if txt == "":
            continue
        if txt in {"間奏", "[間奏]"}:
            continue
        out.append((ts, txt))
    return out


def load_txt_nonempty_lines(path: Path | str) -> list[str]:
    text = path.read_text(encoding="utf-8")
    lines: list[str] = []
    for raw in text.splitlines():
        s = raw.strip("\ufeff").rstrip("\n\r")
        if s.strip() == "":
            continue
        lines.append(s)
    return lines


def reference_times_for_lyrics_txt(lyrics_txt: Path | str, reference_lrc: Path | str) -> list[float]:
    """``lyrics.txt`` の非空行と同じ順の参照時刻一覧（テキスト一致を検証）。"""
    lines = load_txt_nonempty_lines(Path(lyrics_txt))
    entries = parse_lrc_line_times_and_texts(reference_lrc)
    if len(entries) != len(lines):
        raise ValueError(
            f"line count mismatch: lyrics {len(lines)} vs lrc {len(entries)}"
        )
    for i, (ly, (_t, tx)) in enumerate(zip(lines, entries, strict=True)):
        if ly.strip() != tx.strip():
            raise ValueError(f"line {i} text mismatch:\n  lyrics: {ly!r}\n  lrc:    {tx!r}")
    return [t for t, _ in entries]
