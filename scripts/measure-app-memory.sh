#!/usr/bin/env bash
# scripts/measure-app-memory.sh
#
# Prints a one-line RSS breakdown for the running UX-Music.app: the main
# process, its attributed WebKit helper processes (WebContent/GPU/
# Networking, via cmd/measure-app-memory -> pkg/audio.WebKitHelperPIDsFor —
# the same ownership logic the WebView tap itself uses), and the total.
#
# Used to measure the memory saving from Phase 2 (WebView parking) —
# see markdown/background-native-queue-plan.md and progress/webview-parking.md
# for the before/parked/restored numbers this produced.
#
# Usage:
#   scripts/measure-app-memory.sh
#
# Requires the repo's Go toolchain on PATH (invokes `go run
# ./cmd/measure-app-memory`) and a running UX-Music.app.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

APP_PID="$(pgrep -x UX-Music | head -1 || true)"
if [ -z "${APP_PID}" ]; then
    echo "UX-Music.app is not running (pgrep -x UX-Music found nothing)" >&2
    exit 1
fi

app_rss_kb() {
    ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
}

APP_RSS_KB="$(app_rss_kb "${APP_PID}")"
if [ -z "${APP_RSS_KB}" ]; then
    echo "Failed to read RSS for UX-Music PID ${APP_PID}" >&2
    exit 1
fi

WEBKIT_RSS_KB=0
WEBKIT_PID_COUNT=0
while IFS= read -r helper_pid; do
    [ -z "${helper_pid}" ] && continue
    helper_rss="$(app_rss_kb "${helper_pid}")"
    [ -z "${helper_rss}" ] && continue
    WEBKIT_RSS_KB=$((WEBKIT_RSS_KB + helper_rss))
    WEBKIT_PID_COUNT=$((WEBKIT_PID_COUNT + 1))
done < <(go run ./cmd/measure-app-memory --pid "${APP_PID}" 2>/dev/null || true)

TOTAL_KB=$((APP_RSS_KB + WEBKIT_RSS_KB))

to_mb() {
    awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1024 }'
}

printf 'app=%sMB webkit(%d procs)=%sMB total=%sMB\n' \
    "$(to_mb "${APP_RSS_KB}")" "${WEBKIT_PID_COUNT}" "$(to_mb "${WEBKIT_RSS_KB}")" "$(to_mb "${TOTAL_KB}")"
