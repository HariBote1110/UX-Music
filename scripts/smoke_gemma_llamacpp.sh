#!/usr/bin/env bash
# Gemma 4 E2B GGUF smoke test via llama-server (llama.cpp).
#
# Confirms:
#   1. llama-server is on PATH (brew install llama.cpp)
#   2. The model file exists at the expected cache path
#   3. /completion endpoint returns sensible Japanese for a music-curator prompt
#
# llama-server's /v1/chat/completions endpoint silently returned empty
# content with this Gemma 4 build (with and without --jinja), so we use
# /completion with an explicit Gemma chat template. This is the contract
# the Go runtime will adopt.
#
# Run: ./scripts/smoke_gemma_llamacpp.sh
set -euo pipefail

MODEL_PATH="${UX_MUSIC_GEMMA_MODEL:-$HOME/.cache/ux-music/models/gemma-4-E2B_q4_0-it.gguf}"
PORT="${UX_MUSIC_GEMMA_PORT:-18080}"
HOST="127.0.0.1"

command -v llama-server >/dev/null || { echo "llama-server not found. Try: brew install llama.cpp" >&2; exit 1; }
[ -f "$MODEL_PATH" ] || { echo "model not found: $MODEL_PATH" >&2; exit 1; }

echo "starting llama-server on $HOST:$PORT…"
LOG=$(mktemp)
llama-server -m "$MODEL_PATH" --host "$HOST" --port "$PORT" -c 4096 > "$LOG" 2>&1 &
PID=$!
trap "kill $PID 2>/dev/null || true" EXIT

# Wait for /health to return 200 (model load can take 10-30s).
SECS=0
until curl -s -o /dev/null -w "%{http_code}" "http://$HOST:$PORT/health" 2>/dev/null | grep -q 200; do
    if ! kill -0 $PID 2>/dev/null; then
        echo "server died. log tail:" >&2
        tail -20 "$LOG" >&2
        exit 1
    fi
    SECS=$((SECS + 2))
    if [ "$SECS" -gt 120 ]; then
        echo "timeout waiting for server" >&2
        exit 1
    fi
    sleep 2
done
echo "server ready after ~${SECS}s"

PROMPT='<start_of_turn>user
あなたは音楽キュレーターです。「夜のドライブで聴きたい J-POP 特集」というテーマで、200字程度の日本語紹介文を1段落だけ書いてください。本文のみ、前置き不要。<end_of_turn>
<start_of_turn>model
'

REQ=$(python3 -c "
import json, os
print(json.dumps({
    'prompt': os.environ['PROMPT'],
    'n_predict': 400,
    'temperature': 0.7,
    'stop': ['<end_of_turn>']
}))
" PROMPT="$PROMPT")

RESP=$(curl -s "http://$HOST:$PORT/completion" -H "Content-Type: application/json" -d "$REQ")

python3 - <<PY
import json
r = json.loads('''$RESP''')
c = r.get('content', '')
t = r.get('timings', {})
print(f"content length : {len(c)}")
print(f"tokens predict : {r.get('tokens_predicted')}")
print(f"speed          : {t.get('predicted_per_second', 0):.1f} tok/s")
print('--- generated ---')
print(c)
print('--- end ---')
assert len(c) > 50, 'expected non-trivial Japanese output'
print('smoke ok')
PY
