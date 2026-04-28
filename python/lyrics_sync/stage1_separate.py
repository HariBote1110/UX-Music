"""Demucs vocal separation — outputs path to WAV with vocals."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


def ffmpeg_to_wav16_mono(input_audio: str, out_wav: str) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg not found on PATH")
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
        raise RuntimeError(f"ffmpeg failed: {proc.stderr[:400]}")


def run_demucs_vocals(wav_path: str, work_dir: str, emit) -> str:
    """
    Run Demucs htdemucs and return path to extracted vocals WAV.
    """
    demucs = shutil.which("demucs") or shutil.which("python")
    separated_root = Path(work_dir) / "separated"
    separated_root.mkdir(parents=True, exist_ok=True)

    if demucs and Path(demucs).name != "python":
        cmd = [
            demucs,
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
        proc = subprocess.run(cmd, cwd=work_dir, capture_output=True, text=True, env=env)
        if proc.returncode != 0:
            raise RuntimeError(f"demucs failed:\nstdout={proc.stdout[:600]}\nstderr={proc.stderr[:600]}")
        emit("separate_demucs_done", 40.0)
    else:
        # Fall back to Python module invocation
        cmd = ["python", "-m", "demucs", "-n", "htdemucs", "--two-stems", "vocals", "-o", str(separated_root), wav_path]
        proc = subprocess.run(cmd, cwd=work_dir, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"demucs module failed:\n{proc.stderr[:600]}")
        emit("separate_demucs_done", 40.0)

    wav_name = Path(wav_path).stem
    candidate = separated_root / "htdemucs" / wav_name / "vocals.wav"
    if not candidate.exists():
        # alternative layout
        for p in separated_root.glob("**/vocals.wav"):
            return str(p)
        raise RuntimeError("vocals.wav not produced by Demucs")
    return str(candidate)


def separate_vocals(song_path: str, emit) -> tuple[str, str]:
    emit("separate_prep", 2.0)
    work = tempfile.mkdtemp(prefix="uxmusic-demucs-")
    src_wav = str(Path(work) / "prep.wav")
    ffmpeg_to_wav16_mono(song_path, src_wav)
    emit("separate_prep", 14.0)
    vocals_path = run_demucs_vocals(src_wav, work, emit)
    emit("separate", 62.0)
    return vocals_path, work
