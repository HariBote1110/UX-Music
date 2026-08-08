"""Smoke test for dummy pipeline (stdlib only — collected by pytest)."""

from __future__ import annotations

import json
import os
import subprocess
import sys

import pytest


def _run_dummy_pipeline() -> subprocess.CompletedProcess:
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    py_dir = os.path.join(root, "python")
    env = os.environ.copy()
    env["PYTHONPATH"] = py_dir
    env["UX_MUSIC_LYRICS_SYNC_DUMMY"] = "1"
    return subprocess.run(
        [sys.executable, "-m", "lyrics_sync", "--request"],
        input=json.dumps({"songPath": "/dev/null", "lines": ["a", "b"]}).encode(),
        capture_output=True,
        cwd=root,
        env=env,
        check=False,
    )


@pytest.fixture(scope="module")
def dummy_run() -> subprocess.CompletedProcess:
    """Run the dummy sidecar once and share the result across this module's tests."""
    return _run_dummy_pipeline()


def test_dummy_pipeline_exits_cleanly_with_success_payload(dummy_run) -> None:
    assert dummy_run.returncode == 0, dummy_run.stderr.decode()
    decoded = json.loads(dummy_run.stdout.decode().strip())
    assert decoded.get("success") is True
    assert [row["text"] for row in decoded.get("lines", [])] == ["a", "b"]


def test_dummy_pipeline_emits_dummy_stage_progress(dummy_run) -> None:
    stderr_lines = dummy_run.stderr.decode().strip().splitlines()
    stages = [json.loads(ln).get("stage") for ln in stderr_lines if ln.startswith("{")]
    assert "dummy" in stages, stderr_lines
