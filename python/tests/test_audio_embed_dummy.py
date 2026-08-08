"""Smoke test for audio_embed dummy mode (stdlib only).

Run directly: python3 python/tests/test_audio_embed_dummy.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys


def _run(payload: dict) -> tuple[int, str, str]:
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    py_dir = os.path.join(root, "python")
    env = os.environ.copy()
    env["PYTHONPATH"] = py_dir
    env["UX_MUSIC_AUDIO_EMBED_DUMMY"] = "1"
    proc = subprocess.run(
        [sys.executable, "-m", "audio_embed", "--request"],
        input=json.dumps(payload).encode(),
        capture_output=True,
        cwd=root,
        env=env,
        check=False,
    )
    return proc.returncode, proc.stdout.decode(), proc.stderr.decode()


def test_single_song_dummy() -> None:
    code, out, err = _run({"songPath": "/tmp/sample.mp3"})
    assert code == 0, f"non-zero exit. stderr={err}"
    decoded = json.loads(out.strip())
    assert decoded.get("success") is True, decoded
    assert decoded.get("version", "").startswith("audio-embed-v0"), decoded
    embeddings = decoded.get("embeddings")
    assert isinstance(embeddings, list) and len(embeddings) == 1, decoded
    item = embeddings[0]
    assert item["songPath"] == "/tmp/sample.mp3"
    assert item["dim"] == 512
    vec = item["vector"]
    assert isinstance(vec, list) and len(vec) == 512
    assert all(isinstance(x, float) for x in vec)


def test_batch_songs_dummy() -> None:
    payload = {"songPaths": ["/tmp/a.mp3", "/tmp/b.mp3", "/tmp/c.mp3"]}
    code, out, err = _run(payload)
    assert code == 0, f"non-zero exit. stderr={err}"
    decoded = json.loads(out.strip())
    assert decoded.get("success") is True
    assert len(decoded["embeddings"]) == 3
    paths = [e["songPath"] for e in decoded["embeddings"]]
    assert paths == payload["songPaths"]


def test_dummy_is_deterministic_per_path() -> None:
    """Dummy vectors must be reproducible for the same path (test stability)."""
    _, out1, _ = _run({"songPath": "/tmp/stable.mp3"})
    _, out2, _ = _run({"songPath": "/tmp/stable.mp3"})
    v1 = json.loads(out1.strip())["embeddings"][0]["vector"]
    v2 = json.loads(out2.strip())["embeddings"][0]["vector"]
    assert v1 == v2, "dummy embedding should be deterministic for same path"


def test_dummy_differs_across_paths() -> None:
    _, out_a, _ = _run({"songPath": "/tmp/a.mp3"})
    _, out_b, _ = _run({"songPath": "/tmp/b.mp3"})
    va = json.loads(out_a.strip())["embeddings"][0]["vector"]
    vb = json.loads(out_b.strip())["embeddings"][0]["vector"]
    assert va != vb, "different paths should yield different dummy vectors"


def test_missing_input_returns_error() -> None:
    code, out, err = _run({})
    decoded = json.loads(out.strip()) if out.strip() else {}
    assert decoded.get("success") is False, f"expected failure. out={out} err={err}"
    assert "error" in decoded


def test_progress_emitted_on_stderr() -> None:
    _, _, err = _run({"songPaths": ["/tmp/x.mp3", "/tmp/y.mp3"]})
    stderr_lines = [ln for ln in err.strip().splitlines() if ln.strip()]
    progress_lines = [ln for ln in stderr_lines if '"stage"' in ln]
    assert progress_lines, f"no progress JSON on stderr. stderr={err}"


if __name__ == "__main__":
    test_single_song_dummy()
    test_batch_songs_dummy()
    test_dummy_is_deterministic_per_path()
    test_dummy_differs_across_paths()
    test_missing_input_returns_error()
    test_progress_emitted_on_stderr()
    print("audio_embed dummy check ok")
