"""Entry point: `python -m audio_embed --request` reads JSON from stdin."""

from __future__ import annotations

import argparse
import json
import sys

from .cli import emit_progress, isolate_pipeline_stdout, write_result_stdout
from .embedder import embed_request


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
    except Exception as exc:
        write_result_stdout({"success": False, "error": f"stdin json: {exc}"})
        sys.exit(1)

    with isolate_pipeline_stdout():
        result = embed_request(req, emit=emit_progress)
    write_result_stdout(result)


if __name__ == "__main__":
    main()
