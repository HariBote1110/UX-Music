# macOS 非システム dylib 再帰同梱

## 決定

`scripts/build-install-app.sh` の libusb 固有処理を、配布 `.app` 内の全 Mach-O を起点にした一般的な BFS 走査へ置き換える。Homebrew の `opt`/Cellar や Intel prefix の記録パスに依存せず、portaudio、libusb、および将来の cgo dylib を `Contents/Frameworks` へ同梱する。

## 参照書換え

- 実行ファイルと `Contents/MacOS/` 内の Mach-O は `@executable_path/../Frameworks/<name>` を参照する
- Frameworks 内の dylib は `@loader_path/<name>` を参照する
- 同梱 dylib の `LC_ID_DYLIB` は `@executable_path/../Frameworks/<name>` に統一する
- `/usr/lib/` と `/System/` の参照はシステム依存として保持する

## 解決と失敗方針

絶対パスが実在する場合はそれを採用し、それ以外は Homebrew prefix の `lib`、`/opt/homebrew/lib`、`/usr/local/lib`、現在の Mach-O の `LC_RPATH` の順に basename を探す。依存を解決できない場合はエラー終了し、壊れた bundle を黙って出荷しない。

## 検証

`bash scripts/test-build-install-app.sh` の dry-run smoke test を通過。既存 `.app` のコピーに対する `--skip-build` では `libportaudio.2.dylib` を同梱し、メイン実行ファイルと Frameworks 内 dylib の `otool -L` から `/opt/homebrew` と `/usr/local` が消えることを確認した。再実行時は既存 Frameworks 参照を再解決せず、`install_name_tool -change` と Homebrew 探索を省略する。libusb は環境に未導入のため実 bundle では未検証だが、同じ解決・同梱ルーチンで扱う。
