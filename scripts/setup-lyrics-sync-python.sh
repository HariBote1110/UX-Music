#!/usr/bin/env bash
# One-shot: create python/.venv and install lyrics_sync dependencies (local dev).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/python"

PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

if command -v uv >/dev/null 2>&1; then
  echo "Using uv…"
  uv venv --python "$PYTHON_VERSION" .venv
  uv pip install -e '.[dev]'
else
  echo "uv not found — using python3 -m venv (install uv for faster setup: https://github.com/astral-sh/uv)" >&2
  test -x "$(command -v python3)" || { echo "python3 required" >&2; exit 1; }
  python3 -m venv .venv
  # shellcheck source=/dev/null
  source .venv/bin/activate
  pip install -U pip wheel
  pip install -e '.[dev]'
fi

echo ""
echo "Done. venv: $ROOT/python/.venv"
echo "Restart wails dev — the app will pick this venv automatically."
