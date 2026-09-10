#!/usr/bin/env bash
set -euo pipefail

dry_run=0
if [[ "${1:-}" == --dry-run ]]; then
  dry_run=1
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "使い方: scripts/vendor-native-dylibs.sh [--dry-run] <path-to-.app>" >&2
  exit 2
fi

app_source="$1"
frameworks_dir="${app_source}/Contents/Frameworks"

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  if [[ "${dry_run}" != 1 ]]; then
    "$@"
  fi
}

if [[ "$(uname -s)" != Darwin && "${dry_run}" != 1 ]]; then
  echo "ERROR: このスクリプトは macOS (Darwin) 用です" >&2
  exit 1
fi

if [[ ! -d "${app_source}" ]]; then
  if [[ "${dry_run}" == 1 ]]; then
    echo "ネイティブ dylib を再帰的に同梱: ${frameworks_dir}（bundle 未生成のため otool 走査を省略）"
    exit 0
  fi
  echo "ERROR: .app が見つかりません: ${app_source}" >&2
  exit 1
fi

run mkdir -p "${frameworks_dir}"
echo "ネイティブ dylib を再帰的に同梱: ${frameworks_dir}"

vendor_native_dylibs() {
  local contents_dir="${app_source}/Contents"
  local executable_dir="${contents_dir}/MacOS"
  local sidecar_dir="${contents_dir}/Resources/bin"
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
  local reldir=""
  local remaining=""
  local rewrite=""
  local -i segments=0
  local -i index=0
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

  seed_directory() {
    local directory="$1"
    [[ -d "${directory}" ]] || return 0
    while IFS= read -r -d '' candidate; do
      if file "${candidate}" 2>/dev/null | grep -q 'Mach-O'; then
        if ((${#queued[@]} == 0)) || ! path_is_listed "${candidate}" "${queued[@]}"; then
          worklist+=("${candidate}")
          queued+=("${candidate}")
        fi
      fi
    done < <(find "${directory}" -maxdepth 1 -type f -print0)
  }

  seed_directory "${executable_dir}"
  seed_directory "${sidecar_dir}"
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
        rewrite="@executable_path/../Frameworks/${base}"
      elif [[ "${binary}" == "${frameworks_dir}"/* ]]; then
        rewrite="@loader_path/${base}"
      else
        reldir="$(dirname "${binary}")"
        reldir="${reldir#${contents_dir}/}"
        segments=1
        remaining="${reldir}"
        while [[ "${remaining}" == */* ]]; do
          segments=$((segments + 1))
          remaining="${remaining#*/}"
        done
        rewrite="@loader_path/"
        for ((index = 0; index < segments; index++)); do
          rewrite+="../"
        done
        rewrite+="Frameworks/${base}"
      fi
      run install_name_tool -change "${ref}" "${rewrite}" "${binary}"
    done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')

    if [[ "${binary}" == "${frameworks_dir}"/* ]]; then
      base="$(basename "${binary}")"
      run install_name_tool -id "@executable_path/../Frameworks/${base}" "${binary}"
    fi
  done
}

vendor_native_dylibs
