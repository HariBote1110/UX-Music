# メニューバー常駐（NSStatusItem）

## Decision
- `HideWindowOnClose: true` によるバックグラウンド常駐（`background-window-close.md`）に続き、メニューバーからも操作できるよう macOS の `NSStatusItem` をハンドロールした cgo/Objective-C 実装（`server/tray_darwin.go` / `server/tray_darwin.m`）で追加した。
- サードパーティのトレイライブラリ（`github.com/energye/systray` 等）は不採用。理由は下記「代替案」参照。
- メニュー項目（すべて日本語）: 「ウィンドウを表示」「再生/一時停止」「次の曲」「前の曲」「UX Musicを終了」。
  - 「ウィンドウを表示」→ `wailsRuntime.Show(a.ctx)`（`server/app_wails_adapter.go`）。darwin実装を追うと `Show` → `Frontend.Show()` → `mainWindow.ShowApplication()` → `[NSApplication unhide:self]` であり、`HideWindowOnClose` が使う `[NSApp hide:nil]` の対になる呼び出しであることを確認済み。
  - 「再生/一時停止」「次の曲」「前の曲」→ OSメディアキー用に既にある `a.emit("os-media-command", ...)` 経路（`server/app_media.go` → renderer側 `src/renderer/renderer.ts` の `electronAPI.on('os-media-command', ...)`）をそのまま再利用。新しいコマンド経路は作らない。
  - 「UX Musicを終了」→ `wailsRuntime.Quit(a.ctx)`。Cmd+Q / AppMenuのQuit項目と同じ実クイット経路。
- 再生/一時停止ラベルの状態→文字列変換は純粋関数 `trayPlayPauseLabel(playing bool) string`（`server/app_tray.go`）に切り出し、TDDでテストを先に書いた（`server/app_tray_test.go`）。既存の再生状態変更の一元箇所 `updateOSPlaybackState`（`server/app_media.go`）にトレイラベル更新を追加し、個別の呼び出し箇所（`AudioPause`/`AudioResume`/曲終了時）を触らずに同期させた。
- トレイは GUI モードのみで生成する。`initTray()` は `App.Startup` から呼ぶが、`Startup` は Wails が GUI 起動時にしか呼ばないため（`app_wails_adapter.go` の既存コメントで確認済み）、headless（`--serve`）では自然に未実行になる。
- アイコンは 18x18 の白黒（アルファのみ）テンプレート画像を生成して `server/assets/tray_icon_template.png` に埋め込み（`go:embed`）、Objective-C側で `NSImage.template = YES` を設定。ダークモード/ライトモード双方でOS側が自動反転する。
- Dock アイコンの挙動（`LSUIElement`/`NSApplicationActivationPolicy`）は変更していない。トレイ追加後もアプリはDockに通常表示される。

## Alternatives considered
- **`github.com/energye/systray`（Wails連携でよく使われるフォーク）**: `go get` して `systray_darwin.m` を読んだところ、`nativeStart()`（`RunWithExternalLoop` が使う経路）が無条件に `[[NSApplication sharedApplication] setDelegate:owner]` を実行し、独自の `SystrayAppDelegate` に**アプリ全体のdelegateを差し替える**ことが判明した。これは直前に実装した `HideWindowOnClose`（Wails独自delegateの `applicationShouldTerminate` / hide挙動に依存）や Cmd+Q の実クイット経路と衝突するリスクが高く、`Run()`（内部ループを取得）はさらにWailsの `[NSApp run]` と二重に主ループを奪い合う。採用すると「トレイは動くがウィンドウを閉じてもタスクバーアイコンが消える」「Dockクリックで復帰しない」等の回帰が起き得ると判断し、不採用とした。
- **`github.com/getlantern/systray`**: メインループを自前で握りにいく設計で、Wailsと共存できないことがREADME/既知issueレベルで確認できるため検討から除外。
- **ハンドロール cgo/Objective-C（採用）**: `NSStatusBar systemStatusBar` から `NSStatusItem` を作るだけなら `NSApplication` の delegate や実行ループには一切触れずに済む。既存の `server/os_media_darwin.go`（MediaPlayerフレームワーク連携）と同じパターン（`//go:build darwin` + cgo + `//export` コールバック）を踏襲でき、コードベースの一貫性も保てる。

## Constraints・Gotchas
- **NSStatusItem生成はメインスレッド必須**。`Startup` がどのスレッドから呼ばれるかに依存させず、`ux_tray_create` / `ux_tray_set_playpause_label` / `ux_tray_destroy` はすべて `dispatch_async(dispatch_get_main_queue(), ...)` でメインスレッドのCocoaランループに投げている。Wailsがそのランループを既に回しているため、`Startup` 呼び出し時点でランループが未開始でも実行順序上は問題ない（キューされて後で実行される）。
- メニュー項目のクリックコールバックは `//export ux_on_tray_command` で受け、Goの `go callback(...)` で非同期にディスパッチする（`os_media_darwin.go` の `ux_on_media_command` と同じ設計）。メインスレッドをブロックしないため。
- `destroyTray()` は `App.Shutdown` から呼ぶ。`BeforeClose` 側では呼ばない（`HideWindowOnClose` 時はプロセスが生き続けるため、ウィンドウを閉じただけでトレイを消してはいけない）。
- headless(`--serve`)ではビルドタグ `!darwin` ではなく実行時分岐で無効化されるわけではなく、`Startup` 自体が呼ばれないことに依存している。Windows/Linuxビルドでは `server/tray_stub.go`（`!darwin`）が空実装を提供し、cgoに触れずにビルドが通る。
