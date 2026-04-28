"""Tests for faster-whisper lyric biasing helpers."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from lyrics_sync.stage2_asr import _asr_hints_from_lyrics, _lyric_lines_to_prompt


def test_prompt_skips_interlude():
    joined = _lyric_lines_to_prompt(["A", "(interlude)", "B"])
    assert "interlude" not in joined.lower()
    assert "A" in joined and "B" in joined


def test_hints_japanese_language_and_truncation():
    long = "あ" * 2000
    initial, hotwords, lang = _asr_hints_from_lyrics([long])
    assert lang == "ja"
    assert initial is not None and len(initial) <= 900
    assert hotwords is not None and len(hotwords) <= 340


def test_hints_empty_returns_nones():
    assert _asr_hints_from_lyrics([]) == (None, None, None)
