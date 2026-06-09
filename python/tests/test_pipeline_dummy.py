"""Smoke test for dummy pipeline (stdlib only — run: python3 python/tests/test_pipeline_dummy.py)."""

from __future__ import annotations

import json
import os
import subprocess
import sys


def run_check() -> None:
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    py_dir = os.path.join(root, "python")
    env = os.environ.copy()
    env["PYTHONPATH"] = py_dir
    env["UX_MUSIC_LYRICS_SYNC_DUMMY"] = "1"
    proc = subprocess.run(
        [sys.executable, "-m", "lyrics_sync", "--request"],
        input=json.dumps({"songPath": "/dev/null", "lines": ["a", "b"]}).encode(),
        capture_output=True,
        cwd=root,
        env=env,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr.decode()
    out = proc.stdout.decode().strip()
    decoded = json.loads(out)
    assert decoded.get("success") is True
    stderr_lines = proc.stderr.decode().strip().splitlines()
    assert any('"stage"' in ln and "dummy" in ln for ln in stderr_lines)


if __name__ == "__main__":
    run_check()
    print("pipeline dummy check ok")
