# macOS 非システム dylib 再帰同梱

## 決定

`scripts/vendor-native-dylibs.sh` を共有入口とし、配布 `.app` 内の全 Mach-O を起点にした一般的な BFS 走査で同梱する。seed は `Contents/MacOS` と、存在する場合の `Contents/Resources/bin`（cdparanoia / lyrics-sync-swift の sidecar）の両方とする。Homebrew の `opt`/Cellar や Intel prefix の記録パスに依存せず、portaudio、libusb、libcdio*、および将来の cgo dylib を `Contents/Frameworks` へ同梱する。

## 参照書換え

- 実行ファイルと `Contents/MacOS/` 内の Mach-O は `@executable_path/../Frameworks/<name>` を参照する
- Frameworks 内の dylib は `@loader_path/<name>` を参照する
- `Contents/Resources/bin` の sidecar は `@loader_path/../../Frameworks/<name>` を参照する
- 同梱 dylib の `LC_ID_DYLIB` は `@executable_path/../Frameworks/<name>` に統一する
- `/usr/lib/` と `/System/` の参照はシステム依存として保持する

## 解決と失敗方針

絶対パスが実在する場合はそれを採用し、それ以外は Homebrew prefix の `lib`、`/opt/homebrew/lib`、`/usr/local/lib`、現在の Mach-O の `LC_RPATH` の順に basename を探す。依存を解決できない場合はエラー終了し、壊れた bundle を黙って出荷しない。

## 検証

`bash scripts/test-vendor-native-dylibs.sh` と `bash scripts/test-build-install-app.sh` を通過。既存 `.app` のコピーに対する直接実行では `libportaudio.2.dylib` を同梱し、メイン実行ファイルと Frameworks 内 dylib の `otool -L` から `/opt/homebrew` と `/usr/local` が消えることを確認した。二回目は既存 Frameworks 参照を再解決せず、`install_name_tool -change` と Homebrew 探索を省略する。`build-install-app.sh` と `Makefile` は同じ共有スクリプトを呼び出す。`make build` は従来どおりコード署名を行わないため、そこでの `install_name_tool` により sidecar の署名が無効化される点は対象外とし、署名が必要な配布経路では `build-install-app.sh` の ad-hoc 再署名を使う。libusb/libcdio* は環境に未導入のため実 bundle では未検証だが、同じ解決・同梱ルーチンで扱う。
