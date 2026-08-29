#!/usr/bin/env bash
set -euo pipefail

# UX Music をビルドし、macOS の Applications フォルダへ配置する。
# 使い方:
#   scripts/build-install-app.sh
#   scripts/build-install-app.sh --skip-build
#   DRY_RUN=1 scripts/build-install-app.sh

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_name="UX-Music.app"
app_source="${project_root}/build/bin/${app_name}"
destination="/Applications/${app_name}"
skip_build=0
dry_run="${DRY_RUN:-0}"

usage() {
  cat <<'EOF'
使い方: scripts/build-install-app.sh [オプション]

オプション:
  --skip-build       既存の build/bin/UX-Music.app を配置する
  --destination PATH 配置先を変更する（既定: /Applications/UX-Music.app）
  --dry-run          実行せず、実行内容だけ表示する
  -h, --help         このヘルプを表示する
EOF
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  if [[ "${dry_run}" != 1 ]]; then
    "$@"
  fi
}

while (($# > 0)); do
  case "$1" in
    --skip-build)
      skip_build=1
      ;;
    --destination)
      (($# >= 2)) || { echo "ERROR: --destination にはパスが必要です" >&2; exit 2; }
      destination="$2"
      shift
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: 不明なオプションです: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != Darwin && "${dry_run}" != 1 ]]; then
  echo "ERROR: このスクリプトは macOS (Darwin) 用です" >&2
  exit 1
fi

if ((skip_build == 0)); then
  if ! command -v wails >/dev/null 2>&1 && [[ "${dry_run}" != 1 ]]; then
    echo "ERROR: wails コマンドが見つかりません" >&2
    echo "       go install github.com/wailsapp/wails/v2/cmd/wails@latest" >&2
    exit 1
  fi
  run bash -c "cd \"${project_root}\" && wails build"
else
  printf '== build をスキップ ==\n'
fi

# pkg/mtp が直接 import する github.com/ganeshrvel/go-mtpfs/mtp
# （内部で hanwen/usb を利用）は cgo 経由で Homebrew の libusb に動的リンクする。
# wails build はこの外部 dylib を同梱しないため、cdparanoia/lyrics-sync-swift
# 同様に Contents/Frameworks へコピーし、実行バイナリの参照を
# @executable_path 相対へ付け替えて配布可能にする。署名（--deep）より前に
# 行うことで dylib 自身も ad-hoc 署名の対象に含める。
if [[ -d "${app_source}" || "${dry_run}" == 1 ]]; then
  libusb_prefix="$(brew --prefix libusb 2>/dev/null || echo /opt/homebrew/opt/libusb)"
  libusb_dylib="${libusb_prefix}/lib/libusb-1.0.0.dylib"
  frameworks_dir="${app_source}/Contents/Frameworks"
  main_binary="${app_source}/Contents/MacOS/UX-Music"
  run mkdir -p "${frameworks_dir}"
  run cp "${libusb_dylib}" "${frameworks_dir}/libusb-1.0.0.dylib"
  run install_name_tool -change "${libusb_dylib}" "@executable_path/../Frameworks/libusb-1.0.0.dylib" "${main_binary}"
fi

# wails build は linker-signed の .app を出力する（Info.plist 非バインド・
# Identifier=a.out）。この状態では TCC がコード識別子を安定に紐付けられず、
# YouTube 公式再生の音声タップに必要なマイク/音声取り込み許可を付与できない。
# バンドル全体を ad-hoc 署名し直して Info.plist をシールし、使用目的文字列と
# エンタイトルメントを有効化する。
if [[ -d "${app_source}" || "${dry_run}" == 1 ]]; then
  run bash "${project_root}/scripts/sign-macos.sh" "${app_source}"
fi

if [[ ! -d "${app_source}" && "${dry_run}" != 1 ]]; then
  echo "ERROR: ビルド成果物が見つかりません: ${app_source}" >&2
  exit 1
fi

destination_parent="$(dirname "${destination}")"
if [[ ! -d "${destination_parent}" && "${dry_run}" != 1 ]]; then
  echo "ERROR: 配置先の親フォルダが見つかりません: ${destination_parent}" >&2
  exit 1
fi

if [[ -e "${destination}" || -L "${destination}" ]]; then
  run rm -rf "${destination}"
fi
run cp -R "${app_source}" "${destination}"

if [[ "${dry_run}" == 1 ]]; then
  echo "DRY RUN: 実際のビルド・配置は行っていません"
else
  echo "完了: ${destination}"
fi
