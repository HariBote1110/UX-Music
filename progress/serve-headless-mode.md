# `--serve` ヘッドレスモードの完全化（Phase 0-2）

## Decision

- `server.RunHeadlessServe`（`server/app_serve.go`）を新設し、`--serve` の
  実体とした。起動するのは以下のみ:
  - LAN HTTP サーバ（`/v1` 全ルート。`StartLANServer` 経由で mDNS 広告
    `_uxmusic-sync._tcp` も同時に起動する。既存実装がすでにこの2つを
    セットで扱っていたため分離しなかった）
  - Sync 自動ループ（`a.startSyncAutoLoop()`）
  - ライブラリ初期スキャン（`headlessInitialScan`、詳細は下記）
  - 起動しないもの: ローカル再生（`audio.Player`）・MTP監視・CDリップ・
    OSメディアコントロール／Discord Presence・デバイスウォッチャ・
    ダイアログを要する操作。`app.go` の `Startup` はこれらすべてを
    起動するため、`Startup` を呼ばず個別に必要な部分だけ配線している。
- `--sync-serve` は `--serve` の非推奨エイリアスとして存続（起動時に
  stdout へ deprecation メッセージを出す）。検証スクリプトや
  launchd plist の追従修正コストを避けるため、削除ではなく alias 化を選んだ
  （計画書「未確定」項目の決定）。
- `GET /v1/identity` の `roles` に `"headless"` / `"gui"` を追加した。
  - **mDNS TXT の `roles`（`LibraryHost,PlaybackTarget,Controller`）は
    変更していない。** 既存の `TestSyncMDNSAdvertiseInfo_usesHostIdentity`
    が固定文字列を検証しており、mDNS ピア（他デスクトップの自動検出）に
    対して余計な値を混ぜて互換性を壊すリスクを避けるため。
  - `roles` へのモード追加は `identityHandler`（`server/app_identity.go`）
    側だけで行い、`currentServerModeRole()` が `server/app_mode.go` の
    `CurrentServerMode()` を見て `"headless"`/`"gui"` を返す。
  - モードはプロセス起動時に1回だけ `SetServerMode` で確定する
    （GUI: `main.go`、ヘッドレス: `RunHeadlessServe`）。以後は
    `currentServerMode` パッケージ変数を読むだけで、リクエストのたびに
    判定ロジックを持たない。
- グレースフルシャットダウン: `RunHeadlessServe` は SIGINT/SIGTERM を
  `signal.Notify` で待ち受け、受信したら `context.CancelFunc` を呼ぶ。
  `StartLANServer` はすでに `ctx.Done()` で HTTP サーバと mDNS を
  クローズするゴルーチンを持っていたため、それに乗せるだけで済んだ。
  以前の `select {}` を置き換えた。
- `POST /v1/local/shutdown`（`server/app_local.go`）を新設。
  - 到達条件は「ヘッドレスモードである」かつ「リクエスト元がループバック
    （127.0.0.1/::1）である」の両方。どちらか一方でも欠けると **404**
    を返す（ルート自体が存在しないように振る舞う。401ではなく404にした
    のは「外部からはこのエンドポイントの存在自体を知られない」という
    要求のため）。
  - `deviceAuthMiddleware` の `isPublicLANEndpoint` にパスを追加して
    通常のBearerトークン認証をバイパスしている（このエンドポイント自身の
    ループバック判定が認証の代わりを果たす）。
  - GUIモードでは常に404（launchd ハンドオフの主経路は launchctl 経由の
    停止であり、このエンドポイントは launchctl が使えない異常系の
    フォールバックとして Phase 0-3 で使う想定。GUIで誤って叩かれても
    何も起きないようにする）。

## ライブラリスキャンの扱い（headless equivalent）

- 調査の結果、Goサイドに周期スキャン・ファイルシステムウォッチャは
  存在しない。`ScanLibrary`（`server/app_scanner.go`）はレンダラーが
  Wails バインディング経由で呼ぶ以外の起動経路を持たない
  （`fsnotify` 等の依存も未使用）。
- 最小限の忠実な代替として、`--serve` 起動時に一度だけ
  `settings.libraryPath`（すでに GUI で設定済みの前提）を対象に
  `ScanLibrary` を実行することにした（`headlessInitialScan`）。
  - `libraryPath` が未設定の場合はダイアログを開けないため、エラーに
    せずログを出してスキップする。
  - スキャン元とインポート先が同一パスになるため、`importSongsToLibrary`
    のコピー処理は `samePath` 判定で実質スキップされ、単純な再インデックス
    として動く。
  - **周期再スキャンは実装していない**（元々 Go 側に存在しなかった機能を
    ヘッドレス化の名目で新設しない、というスコープ限定の判断）。
    ヘッドレス稼働中に外部からファイルを追加したい場合は、現状は
    GUI を一度起動してスキャンするか、次回 `--serve` 起動時の初期
    スキャンを待つ必要がある。この制約は Phase 0-3 以降で
    再検討候補とする。

## Alternatives considered

- **`--serve` にも `Startup` をそのまま流用し、内部で各機能を
  if 分岐で止める案**: `Startup` はすでに音声・MTP・デバイス監視など
  ヘッドレスで動かしてはいけないものを大量に含み、分岐だらけになって
  可読性が落ちるため不採用。ヘッドレスが必要とする3つの機能
  （LANサーバ／Sync自動ループ／初期スキャン）だけを個別に呼ぶ構成にした。
- **mDNS TXT の `roles` にも `headless`/`gui` を混ぜる案**: 既存テストと
  既存ピアの解釈を壊すリスクがあるため見送り、`/v1/identity` の
  JSON `roles` のみに追加する非対称な設計にした。
- **周期スキャンやファイルウォッチャをこの Phase で新設する案**:
  計画書は「Go サイドに既存の仕組みがあればそれを使う」という条件付きの
  要求であり、存在しない機能を Phase 0-2 の範囲で新設するのはスコープ
  逸脱と判断し見送った。

## Constraints / Gotchas

- ローカル環境で `go run . --serve` の動作確認をする際、すでに
  `/Applications/UX-Music.app`（実機の GUI インスタンス）がポート 8765
  を握っていると bind に失敗する。1マシン1インスタンス前提
  （Phase 0-3 で launchd ハンドオフを実装するまでは）の制約であり、
  バグではない。
- `RunHeadlessServe` は SIGINT/SIGTERM 受信後、`cancel()` してから
  200ms のスリープを挟んでから return している。`StartLANServer` が
  張るクローズ用ゴルーチンが `ctx.Done()` を観測して `srv.Close()` /
  `mDNS.Shutdown()` を呼び切るのを待つための猶予であり、正確な完了通知
  機構（`sync.WaitGroup` 等）は Phase 0-3 で launchd 連携を詰める際に
  必要なら強化する。
