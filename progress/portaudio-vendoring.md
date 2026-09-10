# PortAudio の静的 vendoring

## Decision

Homebrew の `portaudio-2.0.pc` に依存していた `github.com/gordonklaus/portaudio`
を `third_party/portaudio/` に固定し、Go API は変更せず、PortAudio 19.7.0 の
upstream ソースを cgo の unity-build glue から静的リンクする。macOS は CoreAudio
AUHAL、Linux は ALSA、Windows (mingw) は WASAPI と WMME を有効にする。これにより
fresh clone は Go、Node、Xcode CLT（macOS）だけでビルドできる。

## Alternatives considered

- CoreAudio AUHAL を直接実装する案は、PortAudio の既存 API・デバイス列挙・ホットプラグ対応を失い、既存のプレイヤーとデバイス切替の互換性を壊すため不採用。
- miniaudio は API と挙動の置換範囲が大きく、現行の PortAudio バインディング互換を保てないため不採用。
- ebitengine/oto は出力デバイスの列挙・選択を提供しない。アプリが必要とするデバイス切替とホットプラグ watcher を実装できないため不採用。
- Homebrew の動的 dylib は fresh clone の開発環境と配布 bundle の両方に外部依存を残すため不採用。

## Constraints

PortAudio の版は、今回の Mac が従来 Homebrew で使用していたものと同じ 19.7.0 に固定する。upstream の `third_party/portaudio/portaudio/` は変更せず、OS 別 CFLAGS/defines と framework／system library の LDFLAGS は fork 側に置く。PortAudio の MIT-style ライセンスと copyright 表示を維持する。

## 更新方法

PortAudio を更新するときは、先に対象版の公式ソースを取得して SHA-256 を Homebrew formula と照合し、`third_party/portaudio/portaudio/` を upstream のまま置換する。その後、gordonklaus バインディングの API 差分を確認し、各 OS の glue/config、guard、smoke test、root build、`otool -L`、Linux/Windows CI を実行する。Go の `replace` とこの文書の固定版も同じ変更で更新する。
