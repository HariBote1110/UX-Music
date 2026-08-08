#!/usr/bin/env bash
set -euo pipefail

# UX Music の .app バンドルを ad-hoc 署名し直す。
#
# なぜ必要か:
#   wails build が生成する .app は「linker-signed」（Mach-O のみに署名、
#   Info.plist 非バインド・Identifier=a.out）のため、macOS の TCC が
#   コード識別子を安定に紐付けられない。この状態では YouTube 公式再生の
#   音声プロセスタップに必要なマイク/音声取り込み許可を付与できず、
#   Finder/Dock（open）起動時にタップが無音を返す。
#   バンドル全体を ad-hoc 署名し直すことで Info.plist がシールされ、
#   Identifier が CFBundleIdentifier（com.wails.UX-Music）になり、
#   使用目的文字列（NSMicrophoneUsageDescription 等）とエンタイトルメント
#   （com.apple.security.device.audio-input）が有効化される。
#
# 使い方:
#   scripts/sign-macos.sh                 # build/bin/UX-Music.app を署名
#   scripts/sign-macos.sh /path/to/App.app
#
# 注意:
#   - ad-hoc 署名（-s -）のため、再ビルド・再署名のたびに cdhash が変わり
#     TCC の許可はリセットされる。許可ダイアログの再承認が必要になる。
#   - 配布時は Developer ID 署名 + notarization が別途必要。

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${1:-${project_root}/build/bin/UX-Music.app}"
entitlements="${project_root}/build/darwin/entitlements.plist"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "ERROR: このスクリプトは macOS (Darwin) 用です" >&2
  exit 1
fi
if [[ ! -d "${app_path}" ]]; then
  echo "ERROR: .app が見つかりません: ${app_path}" >&2
  exit 1
fi
if [[ ! -f "${entitlements}" ]]; then
  echo "ERROR: エンタイトルメントが見つかりません: ${entitlements}" >&2
  exit 1
fi

echo "== ad-hoc 署名: ${app_path} =="
codesign --force --deep --sign - \
  --options runtime \
  --entitlements "${entitlements}" \
  "${app_path}"

echo "== 署名検証 =="
codesign -dv --entitlements - "${app_path}" 2>&1 | \
  grep -E "Identifier|Info.plist|Sealed|Signature|flags" || true

echo "完了"
