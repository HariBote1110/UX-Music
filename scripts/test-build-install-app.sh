#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${project_root}/scripts/build-install-app.sh"

if [[ ! -x "${script}" ]]; then
  echo "FAIL: build-install-app.sh が実行可能ではありません" >&2
  exit 1
fi

output="$(DRY_RUN=1 "${script}" 2>&1)"
skip_build_output="$(DRY_RUN=1 "${script}" --skip-build 2>&1)"

grep -Fq "wails" <<<"${output}"
grep -Fq "build" <<<"${output}"
grep -Fq "/Applications/UX-Music.app" <<<"${output}"
grep -Fq "cp -R" <<<"${output}"
grep -Fq "Frameworks" <<<"${output}"
grep -Fq "ネイティブ dylib を再帰的に同梱" <<<"${output}"
grep -Fq "build をスキップ" <<<"${skip_build_output}"
! grep -Fq "brew --prefix libusb" "${project_root}/Makefile"
! rg -n '#cgo[[:space:]]+pkg-config:[[:space:]]*libusb-1\.0|libusb-1\.0-0-dev|mingw-w64-x86_64-libusb' "${project_root}/third_party" "${project_root}/pkg/mtp" "${project_root}/.github" "${project_root}/Makefile"
grep -Fq "vendor-native-dylibs.sh" "${project_root}/Makefile"

echo "PASS: build-install-app.sh の dry-run を確認しました"
