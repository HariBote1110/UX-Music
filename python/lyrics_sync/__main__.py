"""Entry: python -m lyrics_sync --request -"""

from __future__ import annotations

import argparse
import json
import sys

from .cli import emit_progress, isolate_pipeline_stdout, write_result_stdout
from .pipeline import run_pipeline


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--request",
        action="store_true",
        help="Read JSON request from stdin (optional trailing `-` is ignored)",
    )
    ap.add_argument("stdin_dash", nargs="?", default=None)
    args = ap.parse_args()
    if not args.request:
        ap.print_help()
        sys.exit(2)

    try:
        req = json.load(sys.stdin)
    except Exception as e:
        write_result_stdout({"success": False, "error": f"stdin json: {e}"})
        sys.exit(1)

    def emit(stage: str, pct: float) -> None:
        emit_progress(stage, pct)

    with isolate_pipeline_stdout():
        result = run_pipeline(req, emit=emit)
    write_result_stdout(result)


if __name__ == "__main__":
    main()
