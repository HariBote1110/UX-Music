"""Demucs vocal separation — outputs path to WAV with vocals."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def _ffmpeg_bin() -> str:
    p = os.environ.get("UX_MUSIC_FFMPEG", "").strip()
    if p and os.path.isfile(p) and os.access(p, os.X_OK):
        return p
    w = shutil.which("ffmpeg")
    if not w:
        raise RuntimeError("ffmpeg not found (install ffmpeg or set UX_MUSIC_FFMPEG to the app-bundled binary)")
    return w


def ffmpeg_to_wav16_mono(input_audio: str, out_wav: str) -> None:
    ffmpeg = _ffmpeg_bin()
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        input_audio,
        "-ac",
        "1",
        "-ar",
        "44100",
        "-vn",
        out_wav,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {proc.stderr[:800] if proc.stderr else proc.stdout[:400]}")


def _heartbeat(emit, stop: threading.Event) -> None:
    """Keep UI moving while Demucs runs (can take several minutes)."""
    pct = 19.0
    while not stop.is_set():
        try:
            emit("separate_demucs", min(55.0, pct))
        except Exception:
            pass
        pct = min(55.0, pct + 3.0)
        if stop.wait(12.0):
            break


def run_demucs_vocals(wav_path: str, work_dir: str, emit) -> str:
    """
    Run Demucs htdemucs and return path to extracted vocals WAV.
    Prefer the `demucs` console script; otherwise `sys.executable -m demucs` (not `python`).
    """
    separated_root = Path(work_dir) / "separated"
    separated_root.mkdir(parents=True, exist_ok=True)

    demucs_bin = shutil.which("demucs")
    if demucs_bin:
        cmd: list[str] = [
            demucs_bin,
            "-n",
            "htdemucs",
            "--two-stems",
            "vocals",
            "-o",
            str(separated_root),
            wav_path,
        ]
    else:
        # Must use the same interpreter running this sidecar (often `python3`, not `python`).
        cmd = [
            sys.executable,
            "-m",
            "demucs",
            "-n",
            "htdemucs",
            "--two-stems",
            "vocals",
            "-o",
            str(separated_root),
            wav_path,
        ]

    env = os.environ.copy()
    dl = env.get("UX_MUSIC_HF_DOWNLOAD", "")
    if dl == "none":
        env.setdefault("DEMUCS_DOWNLOAD", "skip")

    emit("separate_demucs", 18.0)

    stop_evt = threading.Event()
    hb = threading.Thread(target=_heartbeat, args=(emit, stop_evt), daemon=True)
    hb.start()
    try:
        proc = subprocess.run(cmd, cwd=work_dir, capture_output=True, text=True, env=env, timeout=None)
    finally:
        stop_evt.set()

    if proc.returncode != 0:
        err = (proc.stderr or "") + (proc.stdout or "")
        hint = ""
        if demucs_bin is None:
            hint = (
                "ヒント: Demucs の CLI が無い場合は `pip install demucs` と `python -m pip show demucs` で "
                "`python -m demucs` が使えるか確認してください。"
            )
        raise RuntimeError(
            f"Demucs が失敗しました (exit {proc.returncode}).\n{err[:2400]}\n{hint}"
        )

    emit("separate_demucs_done", 58.0)

    wav_name = Path(wav_path).stem
    candidate = separated_root / "htdemucs" / wav_name / "vocals.wav"
    if candidate.exists():
        return str(candidate)

    for p in sorted(separated_root.glob("**/vocals.wav")):
        return str(p)

    raise RuntimeError(
        "vocals.wav が Demucs の出力に見つかりませんでした。"
        f" 期待: {candidate} (work_dir={work_dir})"
    )


def separate_vocals(song_path: str, emit) -> tuple[str, str]:
    emit("separate_prep", 2.0)
    work = tempfile.mkdtemp(prefix="uxmusic-demucs-")
    try:
        vocals_path = run_demucs_vocals(song_path, work, emit)
    except Exception as direct_err:
        src_wav = str(Path(work) / "prep.wav")
        ffmpeg_to_wav16_mono(song_path, src_wav)
        emit("separate_prep", 14.0)
        try:
            vocals_path = run_demucs_vocals(src_wav, work, emit)
        except Exception as fallback_err:
            raise RuntimeError(
                "Demucs への直接入力と ffmpeg フォールバックの両方が失敗しました。"
                f" 直接入力エラー: {direct_err}"
            ) from fallback_err
    emit("separate", 62.0)
    return vocals_path, work
