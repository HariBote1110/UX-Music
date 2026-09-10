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

# portaudio、libusb、および将来追加される cgo の dylib を含む非システム dylib を
# 再帰的に Contents/Frameworks へ同梱し、Homebrew のインストールを必要としない
# 配布 bundle にする。署名（--deep）より前に行うことで dylib 自身も ad-hoc 署名の
# 対象に含める。
if [[ -d "${app_source}" || "${dry_run}" == 1 ]]; then
  frameworks_dir="${app_source}/Contents/Frameworks"
  run mkdir -p "${frameworks_dir}"
  echo "ネイティブ dylib を再帰的に同梱: ${frameworks_dir}"

  vendor_native_dylibs() {
    local executable_dir="${app_source}/Contents/MacOS"
    local brew_prefix=""
    local binary=""
    local candidate=""
    local base=""
    local ref=""
    local resolved=""
    local target=""
    local own_id=""
    local rpath=""
    local expanded_rpath=""
    local search_path=""
    local -a worklist=()
    local -a rpaths=()
    local -a queued=()
    local -a processed=()

    path_is_listed() {
      local needle="$1"
      local item=""
      shift
      for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
      done
      return 1
    }

    while IFS= read -r -d '' candidate; do
      if file "${candidate}" 2>/dev/null | grep -q 'Mach-O'; then
        worklist+=("${candidate}")
        queued+=("${candidate}")
      fi
    done < <(find "${executable_dir}" -maxdepth 1 -type f -print0)

    brew_prefix="$(brew --prefix 2>/dev/null || true)"

    while ((${#worklist[@]} > 0)); do
      binary="${worklist[0]}"
      worklist=("${worklist[@]:1}")
      if ((${#processed[@]} > 0)) && path_is_listed "${binary}" "${processed[@]}"; then
        continue
      fi
      processed+=("${binary}")

      own_id="$(otool -D "${binary}" 2>/dev/null | sed -n '2p' || true)"
      rpaths=()
      while IFS= read -r rpath; do
        [[ -n "${rpath}" ]] && rpaths+=("${rpath}")
      done < <(otool -l "${binary}" 2>/dev/null | awk '
        /cmd LC_RPATH/ { in_rpath=1; next }
        in_rpath && $1 == "path" { print $2; in_rpath=0; next }
        in_rpath && NF == 0 { in_rpath=0 }
      ')

      while IFS= read -r ref; do
        [[ -z "${ref}" || "${ref}" == "${own_id}" ]] && continue
        if [[ "${ref}" == /usr/lib/* || "${ref}" == /System/* ]]; then
          continue
        fi

        base="${ref##*/}"
        if [[ ("${ref}" == @executable_path/../Frameworks/* || "${ref}" == @loader_path/*) && -e "${frameworks_dir}/${base}" ]]; then
          continue
        fi
        resolved=""
        if [[ "${ref}" == /* && -f "${ref}" ]]; then
          resolved="${ref}"
        else
          if [[ "${ref}" == @loader_path/* ]]; then
            search_path="$(dirname "${binary}")/${base}"
            [[ -f "${search_path}" ]] && resolved="${search_path}"
          elif [[ "${ref}" == @executable_path/* ]]; then
            search_path="${executable_dir}/${base}"
            [[ -f "${search_path}" ]] && resolved="${search_path}"
          fi

          if [[ -z "${resolved}" ]]; then
            while IFS= read -r search_path; do
              [[ -f "${search_path}/${base}" ]] && { resolved="${search_path}/${base}"; break; }
            done < <(
              [[ -n "${brew_prefix}" ]] && printf '%s\n' "${brew_prefix}/lib"
              printf '%s\n' /opt/homebrew/lib /usr/local/lib
              if ((${#rpaths[@]} > 0)); then
                for rpath in "${rpaths[@]}"; do
                  expanded_rpath="${rpath//@loader_path/$(dirname "${binary}")}"
                  expanded_rpath="${expanded_rpath//@executable_path/${executable_dir}}"
                  printf '%s\n' "${expanded_rpath}"
                done
              fi
            )
          fi
        fi

        if [[ -z "${resolved}" ]]; then
          echo "ERROR: 依存 dylib を解決できません: ${ref} (from ${binary})" >&2
          exit 1
        fi

        base="$(basename "${resolved}")"
        target="${frameworks_dir}/${base}"
        if [[ ! -e "${target}" ]]; then
          run cp "${resolved}" "${target}"
          run chmod u+w "${target}"
        fi
        if [[ -e "${target}" ]]; then
          if ((${#queued[@]} == 0)) || ! path_is_listed "${target}" "${queued[@]}"; then
            worklist+=("${target}")
            queued+=("${target}")
          fi
        fi

        if [[ "${binary}" == "${executable_dir}"/* ]]; then
          run install_name_tool -change "${ref}" "@executable_path/../Frameworks/${base}" "${binary}"
        else
          run install_name_tool -change "${ref}" "@loader_path/${base}" "${binary}"
        fi
      done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')

      if [[ "${binary}" == "${frameworks_dir}"/* ]]; then
        base="$(basename "${binary}")"
        run install_name_tool -id "@executable_path/../Frameworks/${base}" "${binary}"
      fi
    done
  }

  if [[ "${dry_run}" == 1 && ! -d "${app_source}" ]]; then
    echo "ネイティブ dylib を再帰的に同梱: ${frameworks_dir}（bundle 未生成のため otool 走査を省略）"
  else
    vendor_native_dylibs
  fi
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
