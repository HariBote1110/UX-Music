"""faster-whisper ASR with word-level timestamps."""

from __future__ import annotations

import os
import sys
from typing import Any


def _apply_cache_env() -> None:
    base = os.environ.get("UX_MUSIC_MODEL_CACHE")
    if not base:
        return
    os.makedirs(base, exist_ok=True)
    os.environ.setdefault("HF_HOME", base)
    os.environ.setdefault("HF_HUB_CACHE", os.path.join(base, "hub"))
    os.environ.setdefault("XDG_CACHE_HOME", base)


def _whisper_language(language: str | None) -> str | None:
    clean = (language or "").strip()
    if not clean or clean.lower() == "auto":
        return None
    return clean


def run_asr(
    vocals_wav: str,
    whisper_model: str,
    emit,
    language: str | None = None,
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

    segments_itr, _info = model.transcribe(
        vocals_wav,
        beam_size=5,
        word_timestamps=True,
        language=_whisper_language(language),
        task="transcribe",
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
