#!/usr/bin/env bash
# One-shot: create python/.venv with a supported CPython (3.10–3.12) and install deps.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/python"

# Optional: PYTHON_FOR_VENV=/opt/homebrew/opt/python@3.12/bin/python3 ./scripts/setup-lyrics-sync-python.sh

have_supported_python() {
  local py="$1"
  "$py" -c 'import sys; v=sys.version_info[:2]; raise SystemExit(0 if (3,10)<=v<=(3,12) else 1)' >/dev/null 2>&1
}

find_python_for_venv() {
  if [[ -n "${PYTHON_FOR_VENV:-}" ]] && [[ -x "${PYTHON_FOR_VENV}" ]] && have_supported_python "${PYTHON_FOR_VENV}"; then
    echo "${PYTHON_FOR_VENV}"
    return 0
  fi
  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    local candidates=(
      "${brew_prefix:+$brew_prefix/opt/python@3.12/bin/python3}"
      /opt/homebrew/opt/python@3.12/bin/python3
      /usr/local/opt/python@3.12/bin/python3
    )
    if command -v brew >/dev/null; then
      local bp
      bp="$(brew --prefix python@3.12 2>/dev/null)/bin/python3" || true
      candidates+=("${bp}")
    fi
    for candidate in "${candidates[@]}"; do
      if [[ -n "$candidate" ]] && [[ -x "$candidate" ]] && have_supported_python "$candidate"; then
        echo "$candidate"
        return 0
      fi
    done
  fi
  if command -v python3.12 >/dev/null 2>&1; then
    local px
    px="$(command -v python3.12)"
    if [[ -x "$px" ]] && have_supported_python "$px"; then
      echo "$px"
      return 0
    fi
  fi
  return 1
}

venv_needs_refresh() {
  if [[ "${RECREATE_VENV:-}" == "1" ]] || [[ "${FORCE:-}" == "1" ]]; then return 0; fi
  local bin_py=""
  if [[ -x .venv/bin/python3 ]]; then
    bin_py=".venv/bin/python3"
  elif [[ -x .venv/Scripts/python.exe ]]; then
    bin_py=".venv/Scripts/python.exe"
  fi
  if [[ -z "$bin_py" ]]; then
    echo "No usable venv yet — will create." >&2
    return 0
  fi
  if "$bin_py" -c 'import sys; v=sys.version_info[:2]; raise SystemExit(0 if (3,10)<=v<=(3,12) else 1)' >/dev/null 2>&1; then
    return 1
  fi
  echo "Existing .venv uses an unsupported Python (need 3.10–3.12) — will recreate." >&2
  return 0
}

PYEXE="$(find_python_for_venv || true)"
if [[ -z "${PYEXE:-}" ]]; then
  echo "Could not find CPython 3.10–3.12 on this machine." >&2
  echo "Try: brew install python@3.12" >&2
  echo "Then re-run: $ROOT/scripts/setup-lyrics-sync-python.sh" >&2
  echo "Or: PYTHON_FOR_VENV=/path/to/python3.12 $ROOT/scripts/setup-lyrics-sync-python.sh" >&2
  exit 1
fi

echo "Using interpreter: $PYEXE ($("$PYEXE" -c 'import sys; print(sys.version.split()[0])'))"

if venv_needs_refresh; then
  echo "Refreshing python/.venv …" >&2
  rm -rf .venv
fi

export UV_PYTHON="${PYEXE}"

if command -v uv >/dev/null 2>&1; then
  echo "Using uv …" >&2
  uv venv --python "${PYEXE}" .venv
  uv pip install -e '.[dev]'
else
  echo "uv not found — using '${PYEXE} -m venv' …" >&2
  "${PYEXE}" -m venv .venv
  # shellcheck source=/dev/null
  source .venv/bin/activate
  pip install -U pip wheel
  pip install -e '.[dev]'
fi

VEXE="${ROOT}/python/.venv/bin/python3"
[[ -x "$VEXE" ]] || VEXE="${ROOT}/python/.venv/Scripts/python.exe"
"$VEXE" -c 'import faster_whisper; print("OK: faster_whisper")'

echo ""
echo "Done. Lyrics sync will use: $("$VEXE" -c "import sys; print(sys.executable)")"
echo "(Restart wails dev.)"
