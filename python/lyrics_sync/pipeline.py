"""End-to-end Request JSON → Result JSON."""

from __future__ import annotations

import os
import shutil
import traceback
from typing import Any, Callable

from .cli import emit_progress


EmitFn = Callable[[str, float], None]


def _dummy_result(req: dict[str, Any]) -> dict[str, Any]:
    lines = req.get("lines") or []
    out_lines: list[dict[str, Any]] = []
    for i, txt in enumerate(lines):
        t = txt.strip().lower()
        if t in {"(interlude)", "[interlude]", "[間奏]"}:
            src = "interlude"
            ts = 0.0
        else:
            src = "interpolated"
            ts = float(i) * 0.5
        out_lines.append(
            {
                "index": i,
                "text": txt,
                "timestamp": ts,
                "confidence": 0.1,
                "source": src,
            }
        )
    return {
        "success": True,
        "lines": out_lines,
        "matchedCount": 0,
        "detectedBy": "dummy",
        "detectedSegments": [],
    }


def run_pipeline(req: dict[str, Any], emit: EmitFn | None = None) -> dict[str, Any]:
    sink = emit or (lambda stage, pct: emit_progress(stage, pct))

    if os.environ.get("UX_MUSIC_LYRICS_SYNC_DUMMY", "").strip() in {"1", "true", "yes"}:
        sink("dummy", 100.0)
        return _dummy_result(req)

    song_path = (req.get("songPath") or "").strip()
    lines = req.get("lines") or []
    whisper_model = (req.get("whisperModel") or os.environ.get("UX_MUSIC_WHISPER_MODEL") or "medium").strip()

    if not song_path or not lines:
        return {"success": False, "error": "invalid payload"}

    work_dir = None
    try:
        from . import stage1_separate, stage2_asr, stage3_align

        sink("separate_start", 1.0)
        vocals_path, work_dir = stage1_separate.separate_vocals(song_path, sink)
        try:
            sink("asr_start", 63.0)
            segments = stage2_asr.run_asr(vocals_path, whisper_model, sink)
            sink("align_start", 97.0)
            aligned, detected = stage3_align.align(lines, segments)
            sink("done", 100.0)
            matched = sum(1 for x in aligned if x.get("source") == "match")
            return {
                "success": True,
                "lines": aligned,
                "matchedCount": matched,
                "detectedBy": "sidecar-v2",
                "detectedSegments": detected,
            }
        finally:
            try:
                if work_dir:
                    shutil.rmtree(work_dir, ignore_errors=True)
            except Exception:
                pass
    except Exception as e:
        tb = traceback.format_exc()
        return {
            "success": False,
            "error": f"{e}\n{tb[-800:]}",
        }
