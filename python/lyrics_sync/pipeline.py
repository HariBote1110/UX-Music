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


def _normalise_audio_sources(req: dict[str, Any]) -> list[str]:
    raw = (
        req.get("audioSources")
        or req.get("audioSourceMode")
        or os.environ.get("UX_MUSIC_LYRICS_SYNC_AUDIO_SOURCES")
        or "both"
    )
    mode = str(raw).strip().lower().replace("_", "-")
    if mode in {"full", "full-audio", "original", "song"}:
        return ["full-audio"]
    if mode in {"vocals", "vocal", "separated", "demucs"}:
        return ["vocals"]
    if mode in {"both", "auto", "all", "full+vocals", "vocals+full"}:
        return ["full-audio", "vocals"]

    parts = [p.strip().lower().replace("_", "-") for p in mode.replace("+", ",").split(",")]
    out: list[str] = []
    for part in parts:
        if part in {"full", "full-audio", "original", "song"} and "full-audio" not in out:
            out.append("full-audio")
        elif part in {"vocals", "vocal", "separated", "demucs"} and "vocals" not in out:
            out.append("vocals")
    return out or ["full-audio", "vocals"]


def _alignment_quality_score(
    lines: list[str],
    aligned: list[dict[str, Any]],
    detected: list[dict[str, Any]],
) -> float:
    lyric_rows = [row for row in aligned if row.get("source") != "interlude"]
    lyric_count = max(1, len([line for line in lines if str(line).strip()]))
    if not lyric_rows:
        return -1000.0

    matched = sum(1 for row in lyric_rows if row.get("source") == "match")
    interpolated = sum(1 for row in lyric_rows if row.get("source") == "interpolated")
    confidences = [float(row.get("confidence", 0.0) or 0.0) for row in lyric_rows]
    valid_times = [
        float(row.get("timestamp", -1.0) or -1.0)
        for row in lyric_rows
        if float(row.get("timestamp", -1.0) or -1.0) >= 0.0
    ]
    if not valid_times:
        return -900.0

    deltas = [b - a for a, b in zip(valid_times, valid_times[1:])]
    monotone_breaks = sum(1 for delta in deltas if delta < -0.05)
    flat_steps = sum(1 for delta in deltas if -0.05 <= delta <= 0.05)
    huge_gaps = sum(1 for delta in deltas if delta > 12.0)
    average_confidence = sum(confidences) / max(1, len(confidences))
    matched_fraction = matched / max(1, lyric_count)
    interpolated_fraction = interpolated / max(1, lyric_count)
    detected_bonus = min(8.0, len(detected) / max(1, lyric_count) * 4.0)

    return (
        matched_fraction * 65.0
        + average_confidence * 30.0
        + detected_bonus
        - interpolated_fraction * 18.0
        - monotone_breaks * 20.0
        - flat_steps * 5.0
        - huge_gaps * 4.0
    )


def _detected_by_for_source(source: str, candidate_count: int) -> str:
    if source == "vocals" and candidate_count == 1:
        return "sidecar-v2"
    return f"sidecar-v2-{source}"


def run_pipeline(req: dict[str, Any], emit: EmitFn | None = None) -> dict[str, Any]:
    sink = emit or (lambda stage, pct: emit_progress(stage, pct))

    if os.environ.get("UX_MUSIC_LYRICS_SYNC_DUMMY", "").strip() in {"1", "true", "yes"}:
        sink("dummy", 100.0)
        return _dummy_result(req)

    song_path = (req.get("songPath") or "").strip()
    lines = req.get("lines") or []
    whisper_model = (req.get("whisperModel") or os.environ.get("UX_MUSIC_WHISPER_MODEL") or "medium").strip()
    language = (req.get("language") or "auto").strip()

    if not song_path or not lines:
        return {"success": False, "error": "invalid payload"}

    work_dir = None
    try:
        from . import stage1_separate, stage2_asr, stage3_align

        source_names = _normalise_audio_sources(req)
        candidates: list[tuple[str, str]] = []
        errors: list[str] = []
        if "full-audio" in source_names:
            candidates.append(("full-audio", song_path))
        if "vocals" in source_names:
            try:
                sink("separate_start", 1.0)
                vocals_path, work_dir = stage1_separate.separate_vocals(song_path, sink)
                candidates.append(("vocals", vocals_path))
            except Exception as separation_error:
                errors.append(f"vocals: {separation_error}")

        results: list[dict[str, Any]] = []

        for idx, (source_name, audio_path) in enumerate(candidates):
            safe_source = source_name.replace("-", "_")
            base_pct = 8.0 + idx * (88.0 / max(1, len(candidates)))
            try:
                sink(f"asr_{safe_source}_start", base_pct)
                segments = stage2_asr.run_asr(audio_path, whisper_model, sink, language=language)
                sink(f"align_{safe_source}_start", min(97.0, base_pct + 38.0))
                aligned, detected = stage3_align.align(lines, segments)
                matched = sum(1 for x in aligned if x.get("source") == "match")
                score = _alignment_quality_score(lines, aligned, detected)
                results.append(
                    {
                        "source": source_name,
                        "audioPath": audio_path,
                        "aligned": aligned,
                        "detected": detected,
                        "matched": matched,
                        "score": score,
                    }
                )
            except Exception as candidate_error:
                errors.append(f"{source_name}: {candidate_error}")

        if not results:
            raise RuntimeError("; ".join(errors) or "no audio source candidates")

        best = max(results, key=lambda item: (float(item["score"]), int(item["matched"])))
        sink("done", 100.0)
        return {
            "success": True,
            "lines": best["aligned"],
            "matchedCount": best["matched"],
            "detectedBy": _detected_by_for_source(str(best["source"]), len(candidates)),
            "detectedSegments": best["detected"],
            "audioSource": best["source"],
            "alignmentQualityScore": round(float(best["score"]), 4),
            "candidateScores": [
                {
                    "source": item["source"],
                    "score": round(float(item["score"]), 4),
                    "matchedCount": item["matched"],
                }
                for item in results
            ],
        }
    except Exception as e:
        tb = traceback.format_exc()
        return {
            "success": False,
            "error": f"{e}\n{tb[-800:]}",
        }
    finally:
        try:
            if work_dir:
                shutil.rmtree(work_dir, ignore_errors=True)
        except Exception:
            pass
