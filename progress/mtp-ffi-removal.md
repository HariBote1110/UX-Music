# MTP: libkalam FFI 廃止と go-mtpfs 直接 import

## Decision
- pkg/mtp の実装を libkalam.dylib（purego FFI + JSON 境界）から github.com/ganeshrvel/go-mtpfs@v1.0.3 の `mtp` パッケージ直接 import に置き換える。
- 高レベル層（パス解決・Walk・転送進捗・MakeDirectory）は pkg/mtp 内に自前実装する。go-mtpx のコードは一切コピーしない（下記ライセンス問題のため）。
- `Manager` の公開 API（メソッド名・引数型）は維持し、Wails 公開 API（server/app_mtp.go）のシグネチャは変えない。ただし `Walk` の戻り値は `interface{}` から型付き `[]FileInfo` に強化（Wails 側は従来同様 JSON 化されるため契約互換）。

## Alternatives considered
- **go-mtpx（高レベル API モジュール）の採用 — 不採用。** kalam 自体が使っており機能的には Walk/進捗/％まで揃うが、リポジトリに LICENSE ファイルが存在せず README にも宣言がない（2026-08-16 に GitHub とモジュールキャッシュ双方で確認）。無ライセンス＝ All rights reserved であり、GPLv3 で配布する本プロジェクトには取り込めない。コード移植（翻案）も派生物になるため不可。挙動の参考（仕様理解）に留める。
  - 副産物の発見: 同梱してきた kalam.dylib 自体が go-mtpx を静的に含んでいた疑いが濃い。FFI 廃止はライセンス衛生の面でも正当。
- **go-mtpfs v1.0.4 系疑似バージョン — 不要。** go-mtpx を使わないため、ユーザー検証済みの v1.0.3 タグで足りる。
- **MTP スタックのゼロ実装 — 不採用（ユーザー判断済み）。**

## Constraints / Gotchas
- v1.0.3 の `mtp` パッケージにはパスベース Walk が**存在しない**。あるのはハンドルベースの GetObjectHandles / GetObjectInfo のみ。パス→ハンドル解決は自前実装が必須。
- 進捗コールバックは `ProgressFunc func(sent int64) error`（累積バイトのみ）。合計サイズは ObjectInfo / ローカル stat から自前で持つ。
- USB 依存は hanwen/usb（New BSD, Copyright 2012 Google Inc.）。ビルドタグなしの cgo + `pkg-config: libusb-1.0` のため、**コンパイルする全 CI ジョブに libusb 開発パッケージが必要**（linux: libusb-1.0-0-dev、Windows msys2: mingw-w64-x86_64-libusb）。
- 配布 .app への同梱: 旧 Makefile / build-install-app.sh は libkalam.dylib を**そもそもコピーしていなかった**（配布版 MTP は非動作だった可能性が高い）。新実装はバイナリが /opt/homebrew の libusb に直接リンクするため、build-install-app.sh で Frameworks へのコピー + install_name_tool の付け替えが必要。
- `mtp` パッケージの stderr 汚染は実質なし（デバッグフラグでゲート済み。例外は Configure 失敗時の log.Printf 1 箇所のみ）。stderr 差し替えハック（stderr_unix.go）は削除できる。
- 「デバイスなし」エラーは `SelectDevice` の型なし文字列 `"no MTP devices found"`。判定が必要なら文字列比較になる点に注意。
