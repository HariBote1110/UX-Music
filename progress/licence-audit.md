# ライセンス構成の棚卸し（GPLv2 → GPLv3 で Apache-2.0 非互換を解消）

**注記:** 法律の専門家による判断ではない。商用配布に関わる決定を下す前に弁護士に確認すること。

## 結論（解決済み）

**2026-08-16、`LICENSE` を GPL-2.0 から GPL-3.0 へ変更した（コミット `b664b6f`）。これにより下記の非互換は解消している。**

## 発見された問題（GPLv3 移行前）

移行前の `LICENSE` は **GPL-2.0**（v2 本文、"or later" の記載なし）で、直接依存に **Apache-2.0** のモジュールが 4 つあった。

| 依存 | ライセンス | 用途 |
|---|---|---|
| `hajimehoshi/go-mp3` | **Apache-2.0** | MP3 デコード |
| `go-audio/wav` | **Apache-2.0** | WAV デコード |
| `go-audio/audio` | **Apache-2.0** | WAV デコードのバッファ型 |
| `ebitengine/purego` | **Apache-2.0** | dylib ロード |
| `mewkiz/flac` | Unlicense | FLAC（自作へ置き換え中） |
| `gordonklaus/portaudio` / `wailsapp/wails` / `kkdai/youtube` / `grandcat/zeroconf` | MIT | — |
| `dhowden/tag` / `mjibson/go-dsp` / `skip2/go-qrcode` | BSD | — |

FSF の見解では **Apache-2.0 は GPLv2 と非互換**（特許終了・補償条項が GPLv2 にない制限を追加するため）で、GPLv3 とは互換。Go は静的リンクなので回避の余地がなかった。

### 検討した選択肢と採用したもの

1. **GPL-3.0 へ変更（採用）** — 1 行の変更で非互換が解消し、かつ「意図して GPL を選んだ」状態になる。
2. Apache-2.0 の 4 つを排除して GPLv2 を維持（不採用） — WAV は自作（RIFF パースは 300 行程度、しかも過去に `FwdToPCM` 後のシーク基準ずれを自力で修正済み）で 2 つ同時に消せるが、go-mp3 と purego の排除まで必要になり労力に見合わない。

なお **WAV デコーダの自作は、ライセンスとは切り離した依存整理として引き続き有効**（Apache-2.0 の go-audio/wav と go-audio/audio を 2 つ同時に排除でき、実装も 300 行程度）。優先度は高くない。

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

- **`libkalam.dylib` の出所とライセンスの特定**（唯一残っている未確認リスク）。
- cdparanoia（GPL-2.0）の同梱は GPLv3 化後も継続。GPL-2.0-only は GPLv3 と非互換だが、`exec` による別プロセス起動で独立したプログラム扱いのため、単一の著作物としてのライセンス衝突は生じないとの理解。将来 GPL を離れる場合はここが障害になる。
- これらの義務はすべて**配布時に発生**する。個人利用のみなら顕在化しない。
