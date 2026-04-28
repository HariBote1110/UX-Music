"""faster-whisper ASR with word-level timestamps."""

from __future__ import annotations

import os
import sys
from typing import Any

from .phoneme import is_interlude, japanese_fraction


def _lyric_lines_to_prompt(lines: list[str]) -> str:
    """Join user-facing lines (skip interlude markers) for Whisper biasing."""
    parts: list[str] = []
    for ln in lines:
        s = (ln or "").strip()
        if not s or is_interlude(ln):
            continue
        parts.append(s)
    return "\n".join(parts)


def _infer_whisper_language(lines: list[str]) -> str | None:
    joined = "".join((ln or "").strip() for ln in lines if not is_interlude(ln or ""))
    if not joined.strip():
        return None
    if japanese_fraction(joined) >= 0.3:
        return "ja"
    return None


def _asr_hints_from_lyrics(lines: list[str]) -> tuple[str | None, str | None, str | None]:
    """
    initial_prompt / hotwords steer ASR toward lyrics the user already typed.
    Truncate conservatively so token limits are not exceeded.
    """
    raw = _lyric_lines_to_prompt(lines)
    if not raw:
        return (None, None, None)
    # initial_prompt seeds the first decoding context; hotwords are applied per window.
    initial = raw[:900] if len(raw) > 900 else raw
    # hotwords capped inside faster-whisper (~max_length//2 tokens).
    hotwords = raw[:340] if len(raw) > 340 else raw
    lang = _infer_whisper_language(lines)
    return (initial.strip() or None, hotwords.strip() or None, lang)


def _apply_cache_env() -> None:
    base = os.environ.get("UX_MUSIC_MODEL_CACHE")
    if not base:
        return
    os.makedirs(base, exist_ok=True)
    os.environ.setdefault("HF_HOME", base)
    os.environ.setdefault("HF_HUB_CACHE", os.path.join(base, "hub"))
    os.environ.setdefault("XDG_CACHE_HOME", base)


def run_asr(
    vocals_wav: str,
    whisper_model: str,
    emit,
    lyric_lines: list[str] | None = None,
) -> list[dict[str, Any]]:
    _apply_cache_env()

    dl = os.environ.get("UX_MUSIC_HF_DOWNLOAD", "")
    if dl == "none":
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        exe = sys.executable
        raise RuntimeError(
            "Python パッケージ「faster-whisper」が見つかりません。"
            f" 現在使用中のインタープリタ ({exe}) に依存関係を入れてください。"
            " 例: cd リポジトリの python && uv venv && uv pip install -e ."
            "（Python 3.10〜3.12 を推奨。pyproject.toml の requires-python を参照）"
        ) from exc

    emit("asr_loading", 64.0)
    device = os.environ.get("UX_MUSIC_WHISPER_DEVICE", "cpu")
    compute_type = os.environ.get("UX_MUSIC_WHISPER_COMPUTE", "int8")
    model_name = whisper_model or "medium"
    model = WhisperModel(model_name, device=device, compute_type=compute_type)
    emit("asr_run", 70.0)

    use_lyric_prompt = os.environ.get("UX_MUSIC_WHISPER_LYRIC_PROMPT", "1").strip().lower() not in {
        "0",
        "false",
        "no",
    }
    initial_prompt: str | None = None
    hotwords: str | None = None
    language: str | None = None
    if use_lyric_prompt and lyric_lines:
        initial_prompt, hotwords, language = _asr_hints_from_lyrics(lyric_lines)

    segments_itr, _info = model.transcribe(
        vocals_wav,
        beam_size=5,
        word_timestamps=True,
        language=language,
        task="transcribe",
        initial_prompt=initial_prompt,
        hotwords=hotwords,
    )

    out: list[dict[str, Any]] = []
    for seg in segments_itr:
        words: list[dict[str, Any]] = []
        if seg.words:
            for tw in seg.words:
                words.append(
                    {
                        "word": tw.word,
                        "start": float(tw.start),
                        "end": float(tw.end),
                    }
                )
        out.append(
            {
                "start": float(seg.start),
                "end": float(seg.end),
                "text": seg.text,
                "words": words,
            }
        )
        emit("asr_run", min(94.0, 70.0 + 22.0 * min(1.0, seg.end / max(180.0, 1e-6))))

    emit("asr_done", 96.0)
    return out
