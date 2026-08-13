# ウィンドウクローズ時のバックグラウンド常駐化

## Decision

- メインウィンドウを閉じても Go プロセスは終了させず、音声再生・LAN API
  (ポート 8765)・YouTube 埋め込みリレーを動かしたまま裏で常駐させる。
- 実装は `main.go` の `wails.Run(&options.App{...})` に対して、以下の3点のみ
  を追加する最小構成にした。
  1. `HideWindowOnClose: true`
  2. `OnBeforeClose: app.BeforeClose`（`server/app_window_close.go` に実装、
     常に `false` を返す）
  3. `Menu: menu.NewMenuFromItems(menu.AppMenu(), menu.EditMenu())`
- ウィンドウの赤信号（クローズ）ボタンを押したときの「隠す」動作は Go 側の
  ロジックを一切介さない。macOS 版 wails v2.11.0 の
  `internal/frontend/desktop/darwin/WindowDelegate.m` の
  `windowShouldClose:` が `hideOnClose`（`HideWindowOnClose` から渡される）
  を見て `[NSApp hide:nil]` を呼び、`false` を返して終わる。つまり
  `OnBeforeClose` フックへは到達しない。
- Dock アイコンをクリックしたときの再表示も、こちらのコードでは何もしていな
  い。`[NSApp hide:nil]` で隠したアプリは、Dock クリックで AppKit が標準の
  unhide（`applicationShouldHandleReopen:` の既定実装）を行い、ウィンドウが
  自動的に前面へ戻る。`AppDelegate.m` は `applicationShouldHandleReopen:` を
  オーバーライドしていないため、この既定動作がそのまま使える。
- Cmd+Q・メニューの Quit・Dock アイコン右クリックの「終了」は、いずれも
  Objective-C 側で `processMessage("Q")` を呼び、
  `internal/frontend/dispatcher/dispatcher.go` の `case 'Q'` 経由で
  `Frontend.Quit()` → `OnBeforeClose(ctx)` を呼び出したうえで
  `mainWindow.Quit()` を実行する（`OnBeforeClose` が `true` を返した場合の
  み実クイットを中止する）。`BeforeClose` は常に `false` を返すため、これら
  の経路は必ず実クイットに到達する。
- ただし、デフォルトでは macOS 側にアプリケーションメニュー自体が存在しな
  い（`WailsContext.m` は空の `NSMenu` を作るだけ）ため、Cmd+Q のキー等価
  が登録されず、キーボードショートカットが機能しない。`menu.AppMenu()` を
  `options.App.Menu` に設定することで、`"Quit " + アプリ名` という
  `NSMenuItem` が `Cmd+Q` のキー等価付きで生成される
  （`WailsMenu.m` 参照）。`EditMenu()` も併せて追加し、標準のコピー/ペースト
  等が使える最低限のメニュー構成にした。

## Alternatives considered

- **`OnBeforeClose` で `runtime.WindowHide`/`runtime.Hide` を呼び `true` を
  返す実装**（当初想定していた設計）: 検証の結果、`HideWindowOnClose` を
  有効にした時点でクローズボタンは `OnBeforeClose` に到達しないため、この
  実装は不要かつ有害と判明。もし `OnBeforeClose` が無条件に `true` を返す
  実装にしていた場合、Cmd+Q や OS のログアウト/シャットダウン時に発火する
  `applicationShouldTerminate` からの終了要求までブロックしてしまい、OS の
  ログアウト処理がハングする恐れがあった。
- **クイット意図フラグ（`RequestQuit()` でセットし `BeforeClose` で判定）**:
  `HideWindowOnClose` によってクローズボタンと実クイットの経路がネイティブ
  側で完全に分離されているため、この Go 側でのフラグ管理は不要と判断し
  採用しなかった。`BeforeClose` は常に `false` を返すだけでよい。
- **`runtime.WindowHide`（Wails のウィンドウ単位 hide API）を明示的に呼ぶ
  案**: `HideWindowOnClose` はアプリ全体を `NSApp hide:` するため、Dock
  クリック時の復帰が AppKit 標準の unhide 挙動に自動的に乗る。
  `WindowHide`/`WindowShow` を自前で使う場合、Dock クリックでの復帰を
  `applicationShouldHandleReopen:` を自前実装して面倒を見る必要があり、
  wails 側の隠し機能（`HideWindowOnClose`）を使う方が実装量・リスクとも
  小さい。

## Constraints・Gotchas

- 対象は wails v2.11.0（`go.mod` 記載のバージョン）。macOS 実装は
  `$(go env GOMODCACHE)/github.com/wailsapp/wails/v2@v2.11.0/internal/frontend/desktop/darwin/`
  以下の Objective-C（`WindowDelegate.m` / `AppDelegate.m` /
  `WailsContext.m` / `WailsMenu.m`）を直接読んで確認した。将来 wails を
  アップグレードした際は、`windowShouldClose:` と
  `applicationShouldTerminateAfterLastWindowClosed:` の実装が変わっていな
  いか再確認すること。
- `AppDelegate.m` の `applicationShouldTerminateAfterLastWindowClosed:` は
  常に `NO` を返す実装になっている。したがって `HideWindowOnClose` の有無
  に関わらず、ウィンドウが（隠れている状態も含め）最後の1つになっても
  プロセスは自動終了しない。
- headless `--serve` パス（`main.go` の `RunSyncCLI` による早期 return）は
  今回変更していない。`wails.Run` 自体を呼ばないため
  `HideWindowOnClose`/`OnBeforeClose`/`Menu` の追加はサーバーモードに一切
  影響しない。
- `BeforeClose` は `server/app_window_close.go` に切り出し、`server` パッケ
  ージの他のテストと同様に `server/app_window_close_test.go` で単体テスト
  している。ロジック自体は「常に `false`」という単純なものだが、退行防止
  （誤って `true` を返す実装に変更されて OS シャットダウンをハングさせる
  事故を防ぐ）を目的としたテストとして残す。
