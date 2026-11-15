#!/usr/bin/env bash
# On-device energy measurement for the UX Music iOS app (Instruments "Power Profiler" attached to
# one process). See mobile_perf_research/notes/device-energy-harness-2026-10.md.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: device_energy.sh --app <path/to/UX-Music-Mobile.app> --scenario <name> --label <text>
                        [--duration 180] [--settle 15] [--background] [--no-install]

Scenarios (DEBUG hooks in UXMusicMobileApp.swift, build with the .perf bundle ID):
  idle_control_visited  Control tab visited once, then Library tab; needs the stub server (auto-started)
  playing_control_visited  tone playing + Control tab visited, then Library (stub server auto-started)
  playing_control_selected tone playing + stays on Control tab; with --background this is fix A's real case
  local_playing         10-minute quiet tone through the normal player
  local_paused          same, paused after ~3 s
  nowplaying_open       local_playing with the Now Playing screen presented
  youtube_hidden        YouTube service playback, Now Playing closed (needs Wi-Fi/internet on the phone)

Options:
  --background   after the settle period, launch Settings so the app goes to the background
  --no-install   skip `devicectl install` (app already installed)

Environment overrides: DEVICE (CoreDevice id), XCTRACE_UDID, PORT (stub, default 8799), LAN_IFACE, YT_VIDEO.
Outputs: mobile_perf_research/tools/out/<label>-<scenario>-<timestamp>.trace + exports, and a line
appended to out/summary.csv. The measurement build must NEVER use the real bundle ID.
USAGE
}

APP="" SCENARIO="" LABEL="" DURATION=180 SETTLE=15 BACKGROUND=0 INSTALL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2;;
    --scenario) SCENARIO="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    --settle) SETTLE="$2"; shift 2;;
    --background) BACKGROUND=1; shift;;
    --no-install) INSTALL=0; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2;;
  esac
done
[[ -n "$APP" && -n "$SCENARIO" && -n "$LABEL" ]] || { usage >&2; exit 2; }
[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"
DEVICE="${DEVICE:-6A208EB1-5443-557E-841D-E2963B59A5CA}"
PORT="${PORT:-8799}"
YT_VIDEO="${YT_VIDEO:-aqz-KE-bpKQ}"
REAL_ID="jp.ux-labs.UXMusicMobile"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
if [[ "$BUNDLE_ID" == "$REAL_ID" || "$BUNDLE_ID" != "$REAL_ID".* ]]; then
  echo "refusing: bundle id '$BUNDLE_ID' is not a measurement id (expected ${REAL_ID}.<suffix>)" >&2
  exit 2
fi

# xctrace addresses the phone by hardware UDID, devicectl by CoreDevice id.
if [[ -z "${XCTRACE_UDID:-}" ]]; then
  xcrun devicectl list devices --json-output "$OUT/.devices.json" >/dev/null 2>&1
  XCTRACE_UDID="$(python3 -I - "$OUT/.devices.json" "$DEVICE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for dev in d["result"]["devices"]:
    if dev["identifier"] == sys.argv[2]:
        print(dev["hardwareProperties"]["udid"])
PY
)"
fi
[[ -n "$XCTRACE_UDID" ]] || { echo "cannot resolve xctrace UDID for $DEVICE" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BGSUF=""
[[ $BACKGROUND == 1 ]] && BGSUF="-bg"
BASE="$OUT/${LABEL}-${SCENARIO}${BGSUF}-${STAMP}"
TRACE="$BASE.trace"
STUB_PID=""
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null || true
  if [[ -n "${APP_PID:-}" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- environment for the scenario -------------------------------------------------------------
ENVJSON="{\"UXM_DEBUG_PERF_SCENARIO\":\"$SCENARIO\"}"
case "$SCENARIO" in
  idle_control_visited|playing_control_visited|playing_control_selected)
    # LAN address of the Mac on its default-route interface (en0 on a Wi-Fi Mac, en1 here on Ethernet).
    IFACE="${LAN_IFACE:-$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')}"
    MAC_IP="$(ipconfig getifaddr "${IFACE:-en0}" || true)"
    [[ -n "$MAC_IP" ]] || { echo "no LAN IP on ${IFACE:-en0} (set LAN_IFACE=...)" >&2; exit 1; }
    python3 -I "$HERE/../../mobile_remote_perf_research/tools/remote_stub_server.py" --port "$PORT" --songs 200 --log-requests \
      >"$BASE.stub.log" 2>&1 &
    STUB_PID=$!
    sleep 1
    kill -0 "$STUB_PID" || { echo "stub server failed to start (see $BASE.stub.log)" >&2; exit 1; }
    ENVJSON="{\"UXM_DEBUG_PERF_SCENARIO\":\"$SCENARIO\",\"UXM_DEBUG_SIDECAR_HOST\":\"$MAC_IP\",\"UXM_DEBUG_SIDECAR_PORT\":\"$PORT\"}";;
  local_playing|local_paused|nowplaying_open) ;;
  youtube_hidden)
    ENVJSON="{\"UXM_DEBUG_YT_VIDEO\":\"$YT_VIDEO\",\"UXM_DEBUG_YT_SERVICE\":\"1\"}";;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2;;
esac

# --- install + launch -------------------------------------------------------------------------
if [[ $INSTALL == 1 ]]; then
  xcrun devicectl device install app --device "$DEVICE" "$APP" >"$BASE.install.log" 2>&1 \
    || { echo "install failed (see $BASE.install.log)" >&2; exit 1; }
fi
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --environment-variables "$ENVJSON" --json-output "$BASE.launch.json" "$BUNDLE_ID" >"$BASE.launch.log" 2>&1 \
  || { echo "launch failed (device locked? see $BASE.launch.log)" >&2; exit 1; }
APP_PID="$(python3 -I - "$BASE.launch.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["result"]["process"]["processIdentifier"])
PY
)"
echo "[$LABEL/$SCENARIO] launched pid=$APP_PID; settling ${SETTLE}s"
sleep "$SETTLE"

if [[ $BACKGROUND == 1 ]]; then
  xcrun devicectl device process launch --device "$DEVICE" com.apple.Preferences >/dev/null 2>&1 \
    || echo "warning: could not launch Settings to background the app" >&2
  sleep 3
fi

# --- record -----------------------------------------------------------------------------------
echo "[$LABEL/$SCENARIO] recording ${DURATION}s -> $TRACE"
REC_START=0 REC_END=0
# xctrace reports "Timed out waiting for device to boot" when the Wi-Fi tunnel has been idle for
# ~10 s; any devicectl call right beforehand wakes it, so list processes (which also checks that the
# app is still alive) immediately before every attempt. Bounded retries.
for attempt in 1 2 3; do
  rm -rf "$TRACE"
  xcrun devicectl device info processes --device "$DEVICE" >"$BASE.processes.log" 2>&1 || true
  grep -q "^$APP_PID " "$BASE.processes.log" || echo "warning: pid $APP_PID not in the process list (app died?)" >&2
  REC_START="$(date +%s)"
  if xcrun xctrace record --device "$XCTRACE_UDID" --template "Power Profiler" --attach "$APP_PID" \
      --time-limit "${DURATION}s" --output "$TRACE" >"$BASE.record.log" 2>&1; then
    break
  fi
  echo "xctrace record attempt $attempt failed: $(tail -1 "$BASE.record.log")" >&2
  [[ $attempt == 3 ]] && { echo "giving up (see $BASE.record.log)" >&2; exit 1; }
  sleep 10
done

REC_END="$(date +%s)"
# Number of HTTP requests the phone sent to the stub while recording (empty without a stub).
STUB_HITS=""
if [[ -n "$STUB_PID" ]]; then
  STUB_HITS="$(awk -v a="$REC_START" -v b="$REC_END" '$1>=a && $1<=b {n++} END {print n+0}' "$BASE.stub.log")"
fi

# --- export + reduce --------------------------------------------------------------------------
EXP="$BASE.export"
mkdir -p "$EXP"
for schema in ProcessSubsystemPowerImpact ProcessQOSExecution SystemPowerLevel device-thermal-state-intervals; do
  xcrun xctrace export --input "$TRACE" \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" >"$EXP/$schema.xml" 2>/dev/null || true
done
python3 -I "$HERE/summarise_trace.py" --dir "$EXP" --pid "$APP_PID" --label "$LABEL" \
  --scenario "${SCENARIO}${BGSUF/-/+}" --duration "$DURATION" --csv "$OUT/summary.csv" \
  ${STUB_HITS:+--stub-requests "$STUB_HITS"}
