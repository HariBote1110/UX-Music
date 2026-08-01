"""Real CLAP smoke test for the audio_embed sidecar.

Gated by env var UX_MUSIC_AUDIO_EMBED_REAL_TEST=1 because it loads a ~2GB
checkpoint and uses librosa's bundled sample. Run:

  UX_MUSIC_AUDIO_EMBED_REAL_TEST=1 \\
    python/.venv/bin/python3 python/tests/test_audio_embed_real.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest


def _gated() -> bool:
    return os.environ.get("UX_MUSIC_AUDIO_EMBED_REAL_TEST", "") == "1"


pytestmark = pytest.mark.skipif(
    not _gated(),
    reason="set UX_MUSIC_AUDIO_EMBED_REAL_TEST=1 to run; loads ~2GB CLAP and needs librosa",
)


def _resolve_sample_audio() -> str:
    import librosa

    return librosa.example("trumpet")


def _run(payload: dict) -> tuple[int, str, str]:
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    py_dir = os.path.join(root, "python")
    venv_py = os.path.join(py_dir, ".venv", "bin", "python3")
    env = os.environ.copy()
    env["PYTHONPATH"] = py_dir
    env.pop("UX_MUSIC_AUDIO_EMBED_DUMMY", None)
    proc = subprocess.run(
        [venv_py if os.path.exists(venv_py) else sys.executable, "-m", "audio_embed", "--request"],
        input=json.dumps(payload).encode(),
        capture_output=True,
        cwd=root,
        env=env,
        check=False,
    )
    return proc.returncode, proc.stdout.decode(), proc.stderr.decode()


def test_real_clap_returns_512dim_vector() -> None:
    audio = _resolve_sample_audio()
    code, out, err = _run({"songPath": audio})
    assert code == 0, f"non-zero exit. stderr tail:\n{err[-2000:]}"
    decoded = json.loads(out.strip())
    assert decoded.get("success") is True, decoded
    assert decoded["version"] == "audio-embed-v0-clap-music-audioset-htsat-tiny"
    embeddings = decoded["embeddings"]
    assert len(embeddings) == 1
    item = embeddings[0]
    assert item["songPath"] == audio
    assert item["dim"] == 512
    vec = item["vector"]
    assert len(vec) == 512
    # CLAP embeddings are roughly unit-normalised; sanity-check non-trivial energy
    energy = sum(v * v for v in vec) ** 0.5
    assert 0.1 < energy < 10.0, f"unexpected vector energy: {energy}"


def test_real_clap_batch_two_paths() -> None:
    audio = _resolve_sample_audio()
    code, out, err = _run({"songPaths": [audio, audio]})
    assert code == 0, f"non-zero exit. stderr tail:\n{err[-2000:]}"
    decoded = json.loads(out.strip())
    assert decoded["success"] is True
    assert len(decoded["embeddings"]) == 2
    # Same path → effectively identical vector (allow tiny FP noise)
    v1 = decoded["embeddings"][0]["vector"]
    v2 = decoded["embeddings"][1]["vector"]
    max_diff = max(abs(a - b) for a, b in zip(v1, v2))
    assert max_diff < 1e-4, f"same file gave divergent vectors (max_diff={max_diff})"


if __name__ == "__main__":
    if not _gated():
        print(
            "skipped (set UX_MUSIC_AUDIO_EMBED_REAL_TEST=1 to run; loads ~2GB CLAP)"
        )
        sys.exit(0)
    test_real_clap_returns_512dim_vector()
    test_real_clap_batch_two_paths()
    print("audio_embed real CLAP check ok")
