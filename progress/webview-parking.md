# WebView 駐機/復帰（Phase 2: バックグラウンドメモリ削減）

`markdown/background-native-queue-plan.md` の Phase 2（WebView 駐機/復帰）実装記録。
Phase 1（`progress/native-play-queue.md`、ネイティブキュー Go 移管）を前提に、
ウィンドウ非表示中の WebContent プロセスを実際に縮小させる。

## 決定

### Go 側: 可視性監視と保留インテント

- `server/app_visibility_darwin.go`/`.m`: `os_media_darwin.go`/`.m` の cgo パターン
  （ARC 前提、`registerOSMediaCommands` 相当の登録関数＋`//export` コールバック）
  にそのまま倣い、`NSApplicationDidHideNotification`/`DidUnhideNotification` を
  `NSNotificationCenter` の default center で監視して `app-visibility-changed`
  （`{"hidden": bool}`）を emit する。非 darwin は no-op スタブ
  （`app_visibility_stub.go`）。`initAppVisibilityObserver()` は `Startup` から
  `initOSMediaControls()` の直後に呼ぶ — `Startup` 自体が Wails の
  `OnStartup` からしか呼ばれない（`main.go`）ため、`initTray()` 等と同じく
  「GUI モード限定」は追加ガードなしで自動的に満たされる。
- `server/app_park.go`: `WindowSetParked(parked bool)` バインディングと
  `ConsumePendingIntent()` バインディングを新設。`App` に `park appParkState`
  （mutex + 単一スロットの `pendingIntent{event, payload}`）を持たせ、
  `emitOrQueueIntent(event, payload)` を唯一の分岐点にした:
  - 非駐機中は `a.emit(event, payload)` と byte-for-byte 同じ。
  - 駐機中は `payload` をスロットへ保存し、`a.emit("wake-request", nil)` を
    代わりに emit する（駐機ページには payload を処理するコードが無いため、
    そのまま渡しても意味がない）。
  - `startQueueItem`（`app_queue.go` の embed 経路）と `app_remote.go` の
    `play-song` ハンドラの計 2 箇所を `a.emit` から `a.emitOrQueueIntent` へ
    置き換えるだけで済んだ。呼び出しシグネチャは同じ。
  - `WindowSetParked(false)` は保留スロットも同時にクリアする — 次回起動の
    `QueueGetState()`/`ConsumePendingIntent()` の組が唯一の復元経路であり、
    前回駐機サイクルの残骸を持ち越すのはバグになるため。

### 駐機ページ（`src/renderer/public/parked.html`）

- Vite の `public/` ディレクトリはビルド出力のルートへそのままコピーされる
  （`vite.config.ts` の `root`/`build.outDir` はデフォルトの `public` 慣習を
  変更していない）。`public/assets/` は既存の `dist/assets/`（JS/CSS チャンク
  の既定出力先）とマージされる形で共存済みなので、`public/parked.html` を
  トップレベルに置けば `dist/parked.html` として配信され、
  `location.replace('/parked.html')` で到達できることを実測確認した
  （`npm run build` 後 `ls dist/parked.html` で存在確認）。
- **Wails ランタイム注入の選択**: Wails v2 は `window.runtime`/`window.go` を
  個別アセット単位ではなく WebView レベル（`WKUserScript`、`forAllFrames`/
  全ナビゲーション適用）で注入する。そのため `parked.html` に
  `<script src="...">` 相当の明示タグは一切不要 — SPA と同じ WebView 内で
  `location.replace` によりナビゲーションするだけで `window.runtime` が
  使える。ただし注入タイミングのレースに備え、`bindRuntimeEvents()` は
  250ms 間隔で最大 20 回リトライしてから諦める。
- **復帰条件（3 種、いずれか）**:
  1. `app-visibility-changed` で `hidden === false`（Dock クリック等での
     再表示）。
  2. `wake-request`（`app_park.go` の `emitOrQueueIntent` — 駐機中に
     再生要求が来た）。
  3. `document.visibilityState` を 2 秒間隔でポーリングし `'visible'` に
     なったら復帰。**設計書は「Go 側に app が隠れていないことを確認する
     追加バインディングを足すか、既存イベントで代用するか」を選択事項として
     残していたが、追加バインディングは足さなかった**: `parked.html` の
     `document.visibilityState` は「このページ（＝この WebView/ウィンドウ）
     が実際に前面表示されているか」を素直に表しており、それ自体が
     「アプリが隠れていない」の定義そのものなので、Go 側の状態と別に
     二重チェックする意味がない。誤検知で早めに起きても実害はほぼない
     （SPA の再読み込みが少し早まるだけ）。
- 画像・SPA バンドルは一切含めない。`main.go` の
  `options.RGBA{27, 38, 54, 1}`（`BackgroundColour`）と同じ `#1b2636` を
  背景色にして、駐機/復帰の切り替わりで白フラッシュしないようにした。

### SPA 側（`src/renderer/js/features/park.ts`）

- `park.ts` を新設（`queue-bridge.ts` を拡張するのではなく別ファイルにした
  — 駐機/復帰は「Go キュー状態のマッピング」とは別の関心事のため）。
  純ロジック（`shouldPark`/`serializeParkedUIState`/
  `deserializeParkedUIState`/`classifyPendingIntent`）と、副作用を持つ
  `initParkBridge`/`parkNow`/`restoreFromPark` を同一ファイルに置いている。
  - `shouldPark({stillHidden, embedActive, isWails})`: デバウンスタイマー
    （`PARK_DELAY_MS = 15000`）が発火した時点で本当に駐機してよいかの純判定。
    3 条件すべて必要（設計書どおり）。
  - `parkNow()` が唯一の駐機実行箇所、`restoreFromPark()` が唯一の復元実行
    箇所 — 将来 Phase 3（Wails フォークの `DestroyWebView`/
    `RecreateWebView`）に差し替える場合もこの 2 関数の中身を変えるだけで
    済むようにした（設計書の「単一シーム」要求）。
- **循環 import 回避**: `park.ts` は `playback-manager.ts` の
  `handleQueuePlayEmbedEvent`/`handleRemotePlaySongEvent`（保留インテントの
  再生を既存ハンドラへ委譲するため）を使う。`playback-manager.ts` 側も
  `initGoQueueBridge()` から `park.ts` の `initParkBridge`/`restoreFromPark`
  を呼ぶ必要があるため、`playback-manager.ts` → `park.ts` の参照は
  `await import('./park.js')` で動的にした（トップレベル循環 import を回避）。
- **配線位置**: `initGoQueueBridge()` の `QueueGetState()` 直後
  （既存の Phase 1 コメントで「Phase 2 の復元シームになる」と予告済みの
  箇所）。順序が重要 — `restoreFromPark()` の保留インテント再生は、
  Go 側のキュー状態がすでに `handleQueueStateChangedEvent` で反映済みで
  あることを前提にしている。
- UI 状態の保存は最小限（設計書の指示どおり）: アクティブな `.nav-link`
  の `data-view` とメインコンテンツのスクロール位置のみ。キュー/再生状態は
  Go が真実源であり sessionStorage には保存しない。

### 実測メモリスクリプト（`scripts/measure-app-memory.sh`）

- `cmd/webkit-helpers`（既存の検証ツール、self 向け）が使っていた
  `pkg/audio` の WebKit ヘルパー所有権判定ロジックを、任意ターゲット PID
  向けに一般化した `audio.WebKitHelperPIDsFor(targetPID int)` を追加
  （既存 `WebKitHelperPIDs()` は内部で `os.Getpid()` を自分自身に固定
  していたため、外部プロセス測定には使えなかった）。非 darwin はエラー
  スタブ（`processtap_other.go`）。
- `cmd/measure-app-memory`: `--pid` を受け取り `WebKitHelperPIDsFor` の
  結果 PID を 1 行 1 個で標準出力するだけの薄いラッパー。
- `scripts/measure-app-memory.sh`: `pgrep -x UX-Music` で本体 PID を取得し、
  `go run ./cmd/measure-app-memory --pid <PID>` で所有 WebKit ヘルパー PID
  を取得、`ps -o rss=` で本体とヘルパー全部の RSS を合算して
  `app=...MB webkit(N procs)=...MB total=...MB` の 1 行を出力する。

## 実測結果（2026-08-20、`wails build` → `build/bin/UX-Music.app` 実機測定）

### 最初の実測は無効だった（レビュー指摘・訂正記録）

初回実装完了時に本節へ記録した数値（起動直後 471.8MB → 駐機後 264.9MB
（~40秒後）→ 復元後 516.3MB）は **無効だった**。レビューで、測定に使った
バイナリが Phase 2 のコード（`app-visibility-changed`/`WindowSetParked`/
`parked.html` 等）を一切含んでいないビルド（`strings` で確認したところ
該当シンボルが 0 件）だったと指摘された。`wails build` 自体は
`public/parked.html` 追加後に実行したはずだったが、実際に測定した
バイナリはそれより前の状態のものだったと考えられる（原因は特定できて
いないが、`wails build` の呼び出しタイミングと測定対象バイナリの取り違え、
または `open -a` 起動時に古いプロセスが生き残っていた可能性が高い —
実際、後続の調査でも「ビルド前に前回のプロセスを確実に kill してから
測定する」手順を踏んでいなかった回があり、同種の取り違えが起きやすい
ワークフローだったことを認める）。**教訓**: 測定前に必ず
(1) 実行中の旧プロセスを `pgrep -x UX-Music` で確認し kill、
(2) `wails build` を実行、
(3) `strings build/bin/UX-Music.app/Contents/MacOS/UX-Music` で対象シンボル
の存在を確認してから測定する、の3点を徹底する。

### デバッグで判明した実際の挙動（発火は正常、メモリ解放が想定よりずっと遅い）

訂正後の再検証時、90秒測定しても WebKit RSS が全く変化しないという
再現性のある結果が最初に出た。`fmt.Printf` の一時デバッグ出力を
`ux_on_app_visibility_changed`（ObjC→Go コールバック）・
`initAppVisibilityObserver` の emit・`WindowSetParked`・
`ConsumePendingIntent`、および `main.go` に一時追加した
`assetserver.Options.Middleware`（AssetServer が実際に受け取った全
HTTPリクエストをログ）で追跡した結果、**チェーン自体は設計どおり正常に
動作している**ことを確認した:

1. `NSApplicationDidHideNotification` は Finder 経由の非表示
   （`tell application "Finder" to set visible of process "UX-Music" to
   false` — 赤い閉じるボタンと同じ `[NSApp hide:nil]` 経路）で即座に発火。
2. `app-visibility-changed`（hidden=true）が emit される。
3. 15秒（`PARK_DELAY_MS`）のデバウンス後、正確に `WindowSetParked(true)`
   が呼ばれる（JS 側のタイマーはバックグラウンドでもスロットリングされず
   ほぼ正確に発火した）。
4. `location.replace('/parked.html')` が例外なく実行され、
   AssetServer は実際に `GET /parked.html` リクエストを受け取り
   （200 で応答、`asset_handler.go` のフォールバック 404 ログは一度も
   出なかった＝Wails 組み込みの embed.FS 配信が正常にヒットしたことを
   意味する）。

つまり **駐機の実行系（可視性検知 → デバウンス → ナビゲーション）は
完全に正しく動いている**。問題は別のところにあった:
WebKit の `WebContent` プロセスは、ページ遷移でヒープ/DOM を解放した
あとも、確保済みページを即座に OS へ返却しない（アロケータのメモリ保持・
遅延トリム）。今回の環境では、`/parked.html` への遷移完了から実際に
`ps` の RSS へ反映されるまで **約 3.5〜4 分** かかった。90秒や以前記録した
「~40秒」という数字はこの遅延の実態を捉えられていなかった
（再検証の一回目でたまたま40秒程度で落ちたように見えた計測は、
むしろ非再現性の高いノイズだったとみられる）。

### 訂正後の実測値（`open -a` 起動、Finder 経由で非表示/再表示、フルサイクル）

`pgrep -x UX-Music` で旧プロセスが無いことを確認 → `wails build` →
`strings` でシンボル存在確認 → `open -a build/bin/UX-Music.app` →
`scripts/measure-app-memory.sh` を 15秒間隔でポーリング。

| 状態 | app (本体) | webkit (3プロセス) | 合計 |
| --- | --- | --- | --- |
| 起動直後（ウィンドウ表示中、baseline） | 153.0MB | 315.3MB | 468.2MB |
| 非表示から ~225–240秒後（実際に落ち始めた時点） | 128.6MB | 113.8MB | 242.4MB |
| 非表示から ~285–345秒後（駐機後、安定） | 127.2〜127.9MB | 101.7〜101.8MB | 229.0〜229.6MB |
| 再表示から数秒後（復元後、安定） | 144.9MB | 373.8〜373.9MB | 518.7〜518.9MB |

- **駐機による削減**: 合計で約 **239MB**（468.2MB → 229.0MB、約 51%減）。
  ほぼ全てが WebKit 側（315.3MB → 101.7MB、約 214MB 減）。
- **駐機の実効化タイミング（重要な訂正）**: `location.replace` 自体は
  非表示化から約15秒後に完了しているが、`ps` の RSS が実際に落ち始めるのは
  **非表示化から約 225〜240秒後**（3.5〜4分後）で、完全に安定するのは
  約 285〜300秒後だった。以前の記録（35〜40秒）は誤りで、実際には
  一桁多い時間スケールで効いてくる。90秒程度の観測では「駐機は効いて
  いない」ように見えるのは、この遅延ゆえに正常な挙動であり、ユーザー/
  レビュアーが実機の赤い閉じるボタンで90秒観測して「WebContent が
  200MB超のまま」と報告したのも、遅延がまだ解消していない時点を
  見ていたためと考えられる（メカニズム自体は壊れていなかった）。
- **実運用上の含意**: このアプリはバックグラウンド再生を主目的に
  `HideWindowOnClose` で常駐させる設計のため、数分単位の遅延は許容範囲
  （数秒〜数十秒閉じてすぐ開き直すような使い方では駐機の恩恵はほぼ
  発生しない点は明記しておく）。より早く確実に解放したい場合は
  Phase 3（Wails フォークの `DestroyWebView`）が必要になる。
- **復元後がベースラインより大きい理由**: 373.8MB（復元後）> 315.3MB
  （起動直後）。SPA 再読み込みによる再パース・再レンダリング・
  ライブラリ再取得のコストが起動直後の状態とわずかに異なるため。
  数十MB差であり、Phase 2 の主目的（非表示中の削減）を損なうものではない。

## 既知の制約・今回やらなかったこと

- **測定はワークロード最小（曲を再生していない状態）で実施**。再生中
  （ローカル/embed 双方）の駐機挙動・メモリ削減幅は未測定 — embed 再生中は
  そもそも `shouldPark` が `embedActive` で駐機を拒否するため測定対象外、
  ローカル再生中の測定は今回のタスク範囲では行っていない。
- **保留インテントの実機シナリオ（駐機中にリモートから play-song が来る/
  キューが embed 曲へ自動進行する）は Go 側ユニットテストでのみ検証**
  （`server/app_park_test.go`、Phase 3 版も同様）。実機での「駐機中に
  Apple TV からリモート再生要求 → 復帰 → 再生開始」の E2E は Phase 2/3
  いずれも行っていない（テスト環境にペア済みリモートクライアントが
  無いため）。Phase 3 でも状況は変わらず未検証。
- Phase 2 時点では「Phase 3（Wails フォークによる DestroyWebView）は
  実測十分のため実施しない」としていたが、実際には Phase 2 のメモリ
  解放が非表示化から 3.5〜4 分後という遅延を伴っていたため、後日
  Phase 3 を実施した（下記セクション参照）。

## Phase 3（2026-08-20 実施）: WebView 破棄方式への切替

Phase 2 の実測で判明した「駐機の実効化（`ps` RSS への反映）が非表示化から
約 3.5〜4 分後」という遅延（WebKit がページ遷移後もヒープを OS へ即座に
返却しないアロケータの保持挙動によるもの）を解消するため、駐機の実装を
「`parked.html` へのナビゲーション」から「`WKWebView` 自体の破棄・再生成」
へ切り替えた。`markdown/background-native-queue-plan.md` の Phase 3。

### 前提: Wails v2 フォーク

`github.com/HariBote1110/wails/v2`（ブランチ `ux-music/webview-destroy`、
コミット `56974de52783...`、`go.mod` の `replace` で適用）に
`runtime.WindowUnloadWebView(ctx)`/`runtime.WindowReloadWebView(ctx)` を
追加してもらったものを利用。`UnloadWebView` は `WKWebView` インスタンスを
最後の強参照ごと解放し（`self.webview = nil`）、WebContent プロセスを
即座に終了させる。`ReloadWebView` は保持しておいた
`WKWebViewConfiguration`（IPC ブリッジの `WKUserContentController` を含む）
を再利用して `WKWebView` を再構築し、起動時と同じ URL を再ロードする —
SPA から見ると「フルリロード」と等価。詳細はフォークの `FORK_NOTES.md`
参照。フォーク自体への変更は行っていない（今回のタスクで見つかった
フォーク側バグは無し）。

### Go 側の変更（`server/app_park.go`、`server/app_wails_adapter.go`、`server/app_media.go`）

- `WindowParkWebView(uiState map[string]interface{})`（新設バインディング）
  が駐機の唯一の入口になった: UI スナップショットを保存し、駐機フラグを
  立て、`windowUnloadWebViewFunc(a.ctx)` を呼ぶ。呼び出し側
  （`park.ts` の `parkNow`）は以前のように別途 `WindowSetParked(true)` を
  呼ぶ必要がない。
- `ConsumeParkedUIState()`（新設バインディング）が UI スナップショットの
  唯一の取り出し口。sessionStorage は WebContent プロセスごと消えるため
  使えなくなり、保存先を Go 側の `appParkState.uiState` に移した。
  take-once（取り出すとクリア）。
- `windowUnloadWebViewFunc`/`windowReloadWebViewFunc`
  （`app_wails_adapter.go`）: `eventsEmitFunc` と同じパッケージ変数
  インダイレクションパターンで、既定は no-op、`wireWailsRuntime`
  （GUI モードの `Startup` からのみ呼ばれる）が実体
  （`wailsRuntime.WindowUnloadWebView`/`WindowReloadWebView`）へ差し替える。
  `app_park.go` は Wails ランタイムを直接 import しない
  （`app_wails_adapter.go` の file-level コメントで「server パッケージ内で
  Wails ランタイムを import してよいのはこのファイルだけ」という既存の
  取り決めを踏襲）。この間接化は headless テストの安全性だけでなく、
  素の `context.Background()`（`frontend` 値を持たない）を
  `wailsRuntime.WindowUnloadWebView` にそのまま渡すと `getFrontend`
  （フォークの `v2/pkg/runtime/runtime.go`）が `log.Fatalf` でテスト
  バイナリごと終了させてしまうという実害を防ぐためでもある
  （最初の実装検討時に気づいた — テストは `windowUnloadWebViewFunc`/
  `windowReloadWebViewFunc` をスパイに差し替えるだけで済む）。
- `emitOrQueueIntent`: 駐機中の分岐は Phase 2 の「`wake-request` イベント
  を emit」から「`reloadWebViewIfParked()` を直接呼ぶ」に変更した。
  駐機中は WebView 自体が破棄されており、`wake-request` を受け取って
  `location.replace` するはずの `parked.html` も存在しないため、
  イベント経由で「起こす」という発想自体が Phase 3 では成立しない
  （イベントは駐機中は安全な no-op になる、FORK_NOTES.md 参照）。
  Go が直接 `WindowReloadWebView` を呼ぶことで WebView を再生成し、
  SPA が起動して `ConsumePendingIntent()` で保留分を回収する、という
  流れに変えた。
- `handleAppVisibilityChanged`（`app_media.go`、`initAppVisibilityObserver`
  のコールバック本体を切り出したもの — ユニットテスト可能にするための
  リファクタ）: `hidden=false` かつ駐機中のとき、`reloadWebViewIfParked()`
  を呼ぶ。これが「ウィンドウを再表示したときの復帰」の起点。ウィンドウを
  隠したまま WebView だけ再生成しても表示状態には影響しない（`attachWebView`
  はコンテンツビューへ追加するだけで `Show` は呼ばない）ため、
  「ウィンドウは隠れたまま WebView を再ロード」という要件は満たしている。
- 二重リロードのレース対策: `reloadWebViewIfParked` は `park.mu` の下で
  `parked` フラグを読んでから呼ぶため、`handleAppVisibilityChanged` と
  `emitOrQueueIntent` がほぼ同時に発火してもリロード要求は直列化される。
  フォークの `ReloadWebView` 自体も「既に WebView があれば no-op」と
  冪等なため、2 回目以降の呼び出しは安全に無視される。
- `WindowSetParked(false)`（`restoreFromPark` が SPA 起動のたびに呼ぶ）は
  引き続き駐機フラグ・保留インテントに加えて UI スナップショットも
  クリアするようにした — 前回サイクルの残骸を持ち越さないという
  Phase 2 からの契約を UI スナップショットにも適用した形。

### SPA 側の変更（`src/renderer/js/features/park.ts`）

- `parkNow()`: `sessionStorage.setItem` + `location.replace('/parked.html')`
  を `WindowParkWebView(captureUIState())` の一呼び出しに置き換えた。
  この呼び出し以降のコードは実行される保証がない
  （呼び出しを発行したこの WebContent プロセス自体が終了しうるため）
  という前提でコメントを整理した。
- `restoreFromPark()`: UI スナップショットの読み出し元を
  `sessionStorage.getItem` から `ConsumeParkedUIState()`（Wails）に
  変更。ブラウザフォールバック用の sessionStorage 経路は削除した —
  `shouldPark` が `isWails` を必須条件にしているため、そもそも
  非 Wails 環境で `parkNow` が呼ばれることはなく、フォールバックを
  残す意味がなかった。
- `deserializeParkedUIState`/`serializeParkedUIState`（JSON 文字列との
  相互変換）は、`WindowParkWebView`/`ConsumeParkedUIState` が既にオブジェクト
  のまま Go↔JS を往復させる（Wails のバインディングが JSON マーシャリングを
  肩代わりする）ため不要になり、形状検証のみを行う `parseParkedUIState`
  に統合した。
- `initParkBridge()` から `wake-request` イベントの購読を削除した
  （Go 側がもう emit しないため — 上記参照）。
- `public/parked.html` を削除した（Phase 2 の駐機ページ。もう到達
  経路が存在しない）。

### 実測結果（`wails build` → `build/bin/UX-Music.app` 実機測定、2026-08-20）

`pgrep -x UX-Music` で旧プロセスが無いことを確認 → `wails build` →
`strings build/bin/UX-Music.app/Contents/MacOS/UX-Music` で
`WindowParkWebView`/`ConsumeParkedUIState`/`WindowUnloadWebView`/
`WindowReloadWebView`/`reloadWebViewIfParked`/`handleAppVisibilityChanged`
の全シンボル存在を確認 → `open` で起動 → `scripts/measure-app-memory.sh`
を 10 秒間隔でポーリング（Phase 2 の教訓を踏まえ、今回はビルド直後に
即座に測定を開始し、バイナリの取り違えを避けた）。

| 時刻 (非表示化からの経過) | app (本体) | webkit | 合計 |
| --- | --- | --- | --- |
| 起動直後（baseline） | 146.4MB | 314.4MB (3 procs) | 460.7MB |
| 非表示化 (`Finder` 経由 hide) | — | — | — |
| +70s（デバウンス発火直後、まだ崩れていない） | 146.5MB | 311.6MB (3 procs) | 458.1MB |
| +80s | 136.9MB | 305.9MB (3 procs) | 442.7MB |
| **+90s（実効化・急落）** | **122.3MB** | **110.5MB (3 procs)** | **232.8MB** |
| +140〜240s（安定） | 124.6〜127.2MB | 111.2〜114.9MB (3 procs) | 235.5〜242.0MB |

- **駐機による削減**: 合計で約 **219〜225MB**（460.7MB → 235.5〜242.0MB、
  約 48%減）。webkit 側だけで見ると 314.4MB → 111〜115MB、約 **200MB
  （64%減）**。Phase 2（約 239MB 減、51%減）とほぼ同等の削減量。
- **実効化タイミングが Phase 2 から劇的に改善**: Phase 2 は非表示化から
  実際に `ps` RSS へ反映されるまで約 225〜240 秒（3.5〜4分）かかったが、
  Phase 3 は **非表示化から約 80〜90 秒**（デバウンス 15 秒＋WebView
  破棄・プロセス終了の実処理で 65〜75 秒程度）で崩れ始め、+90s 時点で
  ほぼ完了していた。10 秒間隔の計測の粒度では「+80s→+90s の 1 回の
  サンプリング間隔でほぼ一気に崩壊」という挙動で、Phase 2 のような
  数分単位のじわじわとした遅延ではなく、`WindowUnloadWebView` 呼び出しに
  伴う WebContent プロセスの実際の終了（デバウンス後、Go 側の処理
  そのものに数十秒かかっている点は今回未計測 — メインスレッド
  ディスパッチ・プロセス終了・OS のページ回収のいずれで時間を
  食っているかまでは切り分けていない）に応じて RSS が反映されたと
  考えられる。当初の設計意図（「15秒のデバウンス後、ほぼ即座に解放」）
  ほど瞬時ではなかったが、Phase 2 比で見れば「数分」から「1〜1.5分」へ
  大幅短縮しており、目的（実運用上意味のある速さでの解放）は達成した。
- **再表示の確認**: `Finder` 経由で再表示すると、`handleAppVisibilityChanged`
  が `reloadWebViewIfParked()` を呼び、ほぼ即座（測定した最短間隔である
  再表示 5 秒後の時点で既に）WebView が再構築され SPA が完全に
  再起動していることを確認した（合計 483.6MB、webkit 336.3MB
  (4 procs) で安定）。スクリーンショットで曲一覧・アートワーク・
  再生バーが正常に描画され操作可能な状態であることも目視確認した。
  復元後がベースラインよりやや大きい（483.6MB vs 460.7MB）のは
  Phase 2 と同じ理由（再パース・再レンダリングコスト）と考えられる。
- **クイック再表示（15秒未満）で駐機しないことの確認**: 非表示化後
  8 秒で再表示したところ、webkit メモリは 186.0MB→187.8MB で安定した
  ままで、駐機時に見られる急落（〜110MB 台）は一切発生しなかった —
  デバウンスタイマーが `shouldPark`/`cancelParkTimer` の設計どおり
  正しくキャンセルされていることを実測でも確認した。
- **保留インテント経路（駐機中にリモート/embed からの再生要求が来る
  シナリオ）は実機 E2E では未検証**。Go 側ユニットテスト
  （`server/app_park_test.go` の
  `TestWindowSetParked_TrueRoutesFutureIntentsToPendingSlotAndTriggersReload`
  ほか）でロジック（駐機中は intent がスロットに積まれ、
  `WindowReloadWebView` が呼ばれ、`wake-request` は emit されない）は
  確認済みだが、実機で「駐機中に Apple TV からリモート再生要求 → 復帰
  → 再生開始」までを通しては検証していない（ペア済みリモート
  クライアントが今回の環境に無いため）。この制約は Phase 2 から
  変わらず持ち越し。

### 既知の制約・今回やらなかったこと（Phase 3）

- 実効化タイミング（+80〜90秒）の内訳（デバウンス後の Go 処理・
  `WindowUnloadWebView` のメインスレッドディスパッチ・WebContent
  プロセスの実終了・OS のページ回収）は切り分けていない。実運用上は
  「Phase 2 の数分待ちより十分速い」という結論で足りると判断した。
- Phase 2 と同様、ワークロード最小（曲を再生していない状態）での測定。
  ローカル/embed 再生中の駐機挙動は今回も未測定。
- フォーク自体（`github.com/HariBote1110/wails`）には手を入れていない。
  見つかったバグも無し。

## 関連ファイル

- Go: `server/app_visibility_darwin.go`/`.m`、`server/app_visibility_stub.go`、
  `server/app_park.go`、`server/app_park_test.go`、`server/app_media.go`
  （`initAppVisibilityObserver`/`handleAppVisibilityChanged`）、
  `server/app_media_test.go`、`server/app.go`（`Startup` 配線・`park`
  フィールド）、`server/app_wails_adapter.go`
  （`windowUnloadWebViewFunc`/`windowReloadWebViewFunc`）、
  `server/app_queue.go`/`app_remote.go`（`emitOrQueueIntent` への置き換え、
  Phase 2 のまま）。
- 実測: `pkg/audio/processtap_darwin.go`/`processtap_other.go`
  （`WebKitHelperPIDsFor`）、`cmd/measure-app-memory/main.go`、
  `scripts/measure-app-memory.sh`。
- SPA: `src/renderer/js/features/park.ts`、
  `src/renderer/js/features/park.test.ts`、
  `src/renderer/js/features/playback-manager.ts`（`initGoQueueBridge` 配線、
  変更なし）。Phase 2 の `public/parked.html` は Phase 3 で削除した。
- wailsjs スタブ（`wails generate` が実行できない開発環境向けの手動追記、
  `progress/native-play-queue.md` の前例に倣う）:
  `src/renderer/wailsjs/go/server/App.d.ts`/`.js`
  （`WindowSetParked`/`ConsumePendingIntent`/`WindowParkWebView`/
  `ConsumeParkedUIState`）。
- フォーク: `github.com/HariBote1110/wails/v2`
  （ローカルソース `/Users/yuki/GitHub/wails`、ブランチ
  `ux-music/webview-destroy`、`FORK_NOTES.md`）。`go.mod` の `replace`
  で `v2.11.1-0.20260820133754-56974de52783` を適用。
