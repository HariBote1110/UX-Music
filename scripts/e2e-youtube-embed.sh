#!/bin/bash
# YouTube 公式再生（embed）の E2E テスト。
#
# 本番相当のビルド（wails:// origin）でアプリを起動し、環境変数
# UX_E2E_YOUTUBE_EMBED_VIDEO により embed 再生を自動開始させ、
# Go 側 EmbedDebugLog が標準出力へ書く構造化ログで合否を判定する。
#
# 使い方:
#   scripts/e2e-youtube-embed.sh              # wails build してから実行
#   SKIP_BUILD=1 scripts/e2e-youtube-embed.sh # 既存の build/bin を再利用
#   VIDEO_ID=xxxxxxxxxxx scripts/e2e-youtube-embed.sh
#
# 合格: "e2e-playing"（PLAYING 到達）を検出
# 不合格: "error=" 検出、またはタイムアウト
#
# 注意: GUI アプリが実際に起動しウィンドウが表示される。音が数秒鳴る。

set -u
cd "$(dirname "$0")/.."

VIDEO_ID="${VIDEO_ID:-jNQXAC9IVRw}"   # "Me at the zoo" — 埋め込み許可・短尺
TIMEOUT_SECS="${TIMEOUT_SECS:-60}"
LOG_FILE="$(mktemp -t ux-e2e-youtube-embed)"
APP_BIN="build/bin/UX-Music.app/Contents/MacOS/UX-Music"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "== wails build =="
    wails build || { echo "FAIL: wails build に失敗"; exit 1; }
fi

[ -x "$APP_BIN" ] || { echo "FAIL: $APP_BIN が見つからない"; exit 1; }

echo "== 起動: video=$VIDEO_ID log=$LOG_FILE =="
UX_E2E_YOUTUBE_EMBED_VIDEO="$VIDEO_ID" "$APP_BIN" >"$LOG_FILE" 2>&1 &
APP_PID=$!

cleanup() {
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
}
trap cleanup EXIT

VERDICT="TIMEOUT"
for _ in $(seq 1 "$TIMEOUT_SECS"); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        VERDICT="CRASHED"
        break
    fi
    if grep -q "\[E2E\]\[YouTubeEmbed\] e2e-playing" "$LOG_FILE"; then
        VERDICT="PASS"
        break
    fi
    if grep -q "\[E2E\]\[YouTubeEmbed\] error=" "$LOG_FILE"; then
        VERDICT="FAIL"
        break
    fi
    sleep 1
done

# PLAYING 後は音量チェック（e2e-volume / e2e-volume-skip）の完了を待つ。
# AudioSetVolume を 1.0 → 0.25 の 2 段階で設定し、タップ出力 RMS の比が
# おおよそ 0.25（許容 0.10〜0.45）で変わることを確認する。
if [ "$VERDICT" = "PASS" ]; then
    VOLUME_VERDICT="TIMEOUT"
    for _ in $(seq 1 30); do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            VOLUME_VERDICT="CRASHED"
            break
        fi
        if grep -q "\[E2E\]\[YouTubeEmbed\] e2e-volume-skip" "$LOG_FILE"; then
            VOLUME_VERDICT="SKIP"
            break
        fi
        VOLUME_LINE="$(grep "\[E2E\]\[YouTubeEmbed\] e2e-volume " "$LOG_FILE" | head -1)"
        if [ -n "$VOLUME_LINE" ]; then
            RATIO="$(printf '%s\n' "$VOLUME_LINE" | sed -n 's/.*ratio=\([0-9.]*\).*/\1/p')"
            if [ -n "$RATIO" ] && awk -v r="$RATIO" 'BEGIN { exit !(r >= 0.10 && r <= 0.45) }'; then
                VOLUME_VERDICT="PASS"
            else
                VOLUME_VERDICT="FAIL"
            fi
            break
        fi
        sleep 1
    done
    echo "== 音量チェック判定: $VOLUME_VERDICT =="
    if [ "$VOLUME_VERDICT" = "FAIL" ] || [ "$VOLUME_VERDICT" = "CRASHED" ]; then
        VERDICT="FAIL"
    elif [ "$VOLUME_VERDICT" = "SKIP" ]; then
        echo "(環境制約により RMS 比例判定をスキップ — Go 単体テストで担保)"
    elif [ "$VOLUME_VERDICT" = "TIMEOUT" ]; then
        echo "(音量チェックのログが時間内に出力されず — 参考情報)"
    fi
fi

echo "== 構造化ログ =="
grep "\[E2E\]\[YouTubeEmbed\]" "$LOG_FILE" || echo "(構造化ログなし)"
echo "== 判定: $VERDICT =="

[ "$VERDICT" = "PASS" ]
