# MTP 用 libusb の静的 vendoring

## Decision

MTP の公開 API と `pkg/mtp` の型・メソッドを変更せず、`go-mtpfs` と
`hanwen/usb` を `third_party/` に固定する方針を採用する。`hanwen/usb` の
`pkg-config: libusb-1.0` 依存は除去し、cgo のソースツリーから libusb をビルドする。
libusb は upstream v1.0.30 に固定する。配置した upstream `libusb/` ソース一式は
SHA-256 `fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`
（公式リリースと同一）で検証済みであり、LGPL-2.1 の `COPYING` を同梱する。

## Alternatives considered

- `github.com/karalabe/usb` は README と公開 API を確認した。generic USB の
  descriptor、interface claim、同期 bulk/control transfer を `go-mtpfs` と互換な
  形では公開しておらず、HID/interrupt 中心のため clean swap にはならない。
- IOKit だけで独自 transport を実装する案は採用しない。libusb の macOS backend
  自体が IOKit を利用し、既存の MTP transport の API を維持できるためである。
- Homebrew の動的 libusb は開発環境依存と配布時の dylib 解決を残すため不採用。
- libusb の LGPL-2.1 静的リンクは、プロジェクト全体の GPLv3 と両立する方針として
  採用し、ライセンス通知に記録する。

## Constraints

macOS の `go build` と `wails dev` が Homebrew libusb なしでリンクできること、
Windows CI の cgo ビルド構成を壊さないこと、`pkg/mtp` と `server/app_mtp.go` の
公開 API を変更しないことを制約とする。native dylib vendoring は portaudio と
libcdio* の汎用処理だけを残し、libusb dylib の同梱処理は削除する。

## 実装記録

MTP の `go-mtpfs` と `hanwen/usb` は repo 内フォークとして保持し、libusb v1.0.30
を cgo の unity-build glue 経由で静的リンクする。macOS は IOKit、CoreFoundation、
Security backend、Linux は usbfs/netlink backend、Windows (mingw) は WinUSB/UsbDk
backend をそれぞれ選択する。OS 別の手書き `config.h` は upstream のソース外に置き、
upstream ファイルは byte-for-byte で保持する。libusb は LGPL-2.1 のため、プロジェクトの GPLv3 と
両立する。`third_party/hanwen-usb/libusb/COPYING` と upstream の著作権表示を
配布物へ含め、フォーク側の `LICENSE` と著作権ヘッダーも保持する。

libusb を更新する場合は、公式リリースの `libusb/` ディレクトリをそのまま置換し、
SHA-256 と `version.h`/`libusb.h` の版を確認する。その後、各 OS の glue/config と
Go smoke test を実行し、API 差分があれば `hanwen/usb` wrapper の互換性を確認する。
