#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${project_root}/scripts/vendor-native-dylibs.sh"
tmp_dir="$(mktemp -d /private/tmp/ux-music-vendor-test.XXXXXX)"
faux_prefix="/tmp/faux"
cleanup() {
  rm -f "${faux_prefix}/libfaux.dylib"
  rmdir "${faux_prefix}" 2>/dev/null || true
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

app="${tmp_dir}/FauxApp.app"
mkdir -p "${faux_prefix}" "${app}/Contents/MacOS" "${app}/Contents/Resources/bin"

cat >"${tmp_dir}/faux.c" <<'EOF'
int faux(void) { return 0; }
EOF
cat >"${tmp_dir}/main.c" <<'EOF'
int faux(void);
int main(void) { return faux(); }
EOF

cc -dynamiclib -install_name /tmp/faux/libfaux.dylib \
  -o "${faux_prefix}/libfaux.dylib" "${tmp_dir}/faux.c"
cc "${tmp_dir}/main.c" -L"${faux_prefix}" -lfaux \
  -o "${app}/Contents/MacOS/App"
cc "${tmp_dir}/main.c" -L"${faux_prefix}" -lfaux \
  -o "${app}/Contents/Resources/bin/sidecar"

first_log="${tmp_dir}/first.log"
second_log="${tmp_dir}/second.log"
bash "${script}" "${app}" >"${first_log}" 2>&1

framework="${app}/Contents/Frameworks/libfaux.dylib"
[[ -f "${framework}" ]]
otool -L "${app}/Contents/MacOS/App" | grep -Fq '@executable_path/../Frameworks/libfaux.dylib'
otool -L "${app}/Contents/MacOS/App" | grep -Fqv '/tmp/faux'
otool -L "${app}/Contents/Resources/bin/sidecar" | grep -Fq '@loader_path/../../Frameworks/libfaux.dylib'
otool -L "${app}/Contents/Resources/bin/sidecar" | grep -Fqv '/tmp/faux'
otool -D "${framework}" | grep -Fq '@executable_path/../Frameworks/libfaux.dylib'

bash "${script}" "${app}" >"${second_log}" 2>&1
! grep -Fq 'install_name_tool -change' "${second_log}"

echo "PASS: vendor-native-dylibs.sh のサイドカー同梱と冪等性を確認しました"
