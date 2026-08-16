# ライセンス構成の棚卸し（GPLv2 と Apache-2.0 の非互換）

**注記:** 法律の専門家による判断ではない。商用配布に関わる決定を下す前に弁護士に確認すること。

## 発見（未解決の問題）

本プロジェクトの `LICENSE` は **GPL-2.0**（v2 本文、"or later" の記載なし）だが、直接依存に **Apache-2.0** のモジュールが 4 つある。

| 依存 | ライセンス | 用途 |
|---|---|---|
| `hajimehoshi/go-mp3` | **Apache-2.0** | MP3 デコード |
| `go-audio/wav` | **Apache-2.0** | WAV デコード |
| `go-audio/audio` | **Apache-2.0** | WAV デコードのバッファ型 |
| `ebitengine/purego` | **Apache-2.0** | dylib ロード |
| `mewkiz/flac` | Unlicense | FLAC（自作へ置き換え中） |
| `gordonklaus/portaudio` / `wailsapp/wails` / `kkdai/youtube` / `grandcat/zeroconf` | MIT | — |
| `dhowden/tag` / `mjibson/go-dsp` / `skip2/go-qrcode` | BSD | — |

FSF の見解では **Apache-2.0 は GPLv2 と非互換**（特許終了・補償条項が GPLv2 にない制限を追加するため）で、GPLv3 とは互換。Go は静的リンクなので回避の余地がない。

### 選択肢

1. **GPL-3.0-or-later（または GPL-2.0-or-later）へ変更** — 1 行の変更で非互換が解消し、かつ「意図して GPL を選んだ」状態になる。
2. **Apache-2.0 の 4 つを排除して GPLv2 を維持** — WAV は自作（RIFF パースは 300 行程度、しかも過去に `FwdToPCM` 後のシーク基準ずれを自力で修正済み）で 2 つ同時に消せる。go-mp3 と purego の排除は別途検討が必要。

## 誤解の訂正: ffmpeg は GPL の原因ではない

ffmpeg は**同梱していない**。`locateFfmpeg()` が実行時に PATH から解決する方式なので、配布物に含まれず GPL の義務が発生しない。Homebrew の ffmpeg が `--enable-gpl --enable-libx264 --enable-libx265` でビルドされていても、それはユーザー環境の話。

## 同梱バイナリの状況

`bin/macos/` および `pkg/mtp/lib/` の中身。

| ファイル | ライセンス | 備考 |
|---|---|---|
| `cdparanoia` | **GPL-2.0** | 唯一同梱している copyleft。Makefile が `.app/Contents/Resources/bin` へコピーする。`exec` で別プロセス起動のため FSF の解釈では独立したプログラム扱いで、Go コード本体へは伝播しない |
| `libusb.dylib` | LGPL-2.1 | 動的リンクのため任意ライセンスで利用可（再リンク可能性の確保は必要） |
| `libkalam.dylib` | **不明** | MTP 用。由来を示す記録がリポジトリ内に無い。**ここが最大の未確認リスク** |
| `xld` | — | 204 バイトのシェルスクリプト。ユーザーが自分でインストールした `/Applications/XLD.app` を呼ぶだけで、XLD 自体は同梱していない |

## 未解決事項

- `libkalam.dylib` の出所とライセンスの特定。
- GPL-3.0-or-later へ移行するか、Apache-2.0 依存を排除するかの選択（未決定）。
- これらの義務はすべて**配布時に発生**する。個人利用のみなら顕在化しない。
