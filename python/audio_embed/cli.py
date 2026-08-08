"""Stdout/stderr discipline for the audio_embed sidecar.

Mirrors lyrics_sync.cli: stdout carries a single JSON result; stderr carries
progress JSON lines so the Go host can stream them.
"""

from __future__ import annotations

import json
import sys
from contextlib import contextmanager
from typing import Generator, TextIO


@contextmanager
def isolate_pipeline_stdout() -> Generator[None, None, None]:
    """Redirect library chatter from stdout to stderr so the result stays clean."""
    saved = sys.stdout
    sys.stdout = sys.stderr
    try:
        yield
    finally:
        sys.stdout = saved


def emit_progress(stage: str, percent: float, sink: TextIO | None = None) -> None:
    """Emit one `{"stage", "percent"}` JSON line on stderr."""
    stream = sink if sink is not None else sys.stderr
    payload = {"stage": stage, "percent": float(max(0.0, min(100.0, percent)))}
    stream.write(json.dumps(payload, ensure_ascii=False) + "\n")
    stream.flush()


def write_result_stdout(result_obj: dict) -> None:
    sys.stdout.write(json.dumps(result_obj, ensure_ascii=False))
    sys.stdout.flush()
