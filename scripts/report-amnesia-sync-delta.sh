#!/usr/bin/env bash
# アムネシア（IGNORE）でフルパイプラインを走らせ、manualversion.lrc との行別ずれを表示する。
#
# Usage（リポジトリルートで）:
#   chmod +x scripts/report-amnesia-sync-delta.sh
#   ./scripts/report-amnesia-sync-delta.sh
#
# 任意の環境変数:
#   UX_MUSIC_SYNC_REPORT_JSON=/tmp/report.json   … 詳細 JSON
#   UX_MUSIC_SYNC_REPORT_TOP_N=20               … 表に出す上位行数
#   UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT=0.45    … 調整ノブ

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/python"

PY=".venv/bin/python"
if [[ ! -x "$PY" ]]; then
  PY="python3"
fi

export UX_MUSIC_IGNORE_INTEGRATION=1

exec "$PY" -m pytest tests/test_ignore_amnesia_manual_reference.py::test_amnesia_auto_sync_vs_manual_lrc_metrics \
  -v -s --tb=short "$@"
