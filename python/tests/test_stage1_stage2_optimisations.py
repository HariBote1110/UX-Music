"""Optimisation checks for the lyrics sync sidecar."""

from __future__ import annotations

import sys
import types
from pathlib import Path


def test_separate_vocals_prefers_direct_input_then_falls_back_to_ffmpeg(monkeypatch, tmp_path):
    from lyrics_sync import stage1_separate

    calls: list[tuple[str, str]] = []

    def fake_run_demucs_vocals(input_audio: str, work_dir: str, emit):
        calls.append((input_audio, work_dir))
        if len(calls) == 1:
            raise RuntimeError("direct demucs failed")
        return str(Path(work_dir) / "separated" / "htdemucs" / "song" / "vocals.wav")

    def fake_ffmpeg_to_wav16_mono(input_audio: str, out_wav: str) -> None:
        calls.append((f"ffmpeg:{input_audio}", out_wav))

    monkeypatch.setattr(stage1_separate, "run_demucs_vocals", fake_run_demucs_vocals)
    monkeypatch.setattr(stage1_separate, "ffmpeg_to_wav16_mono", fake_ffmpeg_to_wav16_mono)
    monkeypatch.setattr(stage1_separate.tempfile, "mkdtemp", lambda prefix: str(tmp_path))

    vocals_path, work_dir = stage1_separate.separate_vocals("/music/song.flac", lambda *_: None)

    assert work_dir == str(tmp_path)
    assert vocals_path.endswith("vocals.wav")
    assert calls[0] == ("/music/song.flac", str(tmp_path))
    assert calls[1] == ("ffmpeg:/music/song.flac", str(tmp_path / "prep.wav"))
    assert calls[2] == (str(tmp_path / "prep.wav"), str(tmp_path))


def test_run_asr_uses_explicit_language_only_when_not_auto(monkeypatch):
    from lyrics_sync import stage2_asr

    captured: list[str | None] = []

    class FakeWhisperModel:
        def __init__(self, model_name: str, device: str, compute_type: str):
            self.model_name = model_name
            self.device = device
            self.compute_type = compute_type

        def transcribe(self, vocals_wav, beam_size, word_timestamps, language, task):
            captured.append(language)
            return ([], {})

    fake_module = types.ModuleType("faster_whisper")
    fake_module.WhisperModel = FakeWhisperModel
    monkeypatch.setitem(sys.modules, "faster_whisper", fake_module)
    monkeypatch.setenv("UX_MUSIC_WHISPER_DEVICE", "cpu")
    monkeypatch.setenv("UX_MUSIC_WHISPER_COMPUTE", "int8")

    stage2_asr.run_asr("/tmp/vocals.wav", "tiny", lambda *_: None, language="auto")
    stage2_asr.run_asr("/tmp/vocals.wav", "tiny", lambda *_: None, language="ja")

    assert captured == [None, "ja"]


def test_pipeline_passes_request_language_to_asr(monkeypatch):
    from lyrics_sync import pipeline, stage1_separate, stage2_asr, stage3_align

    seen: dict[str, object] = {}

    def fake_run_asr(vocals_wav, whisper_model, emit, language=None):
        seen["language"] = language
        return [{"start": 0.0, "end": 1.0, "text": "x", "words": []}]

    monkeypatch.setattr(stage1_separate, "separate_vocals", lambda song_path, emit: ("/tmp/vocals.wav", "/tmp/work"))
    monkeypatch.setattr(stage2_asr, "run_asr", fake_run_asr)
    monkeypatch.setattr(stage3_align, "align", lambda lines, segments: ([], []))

    result = pipeline.run_pipeline(
        {
            "songPath": "/music/song.flac",
            "lines": ["hello"],
            "language": "en",
            "whisperModel": "tiny",
        },
        emit=lambda *_: None,
    )

    assert result["success"] is True
    assert seen["language"] == "en"
