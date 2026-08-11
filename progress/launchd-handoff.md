# launchd 常駐と GUI ハンドオフ（Phase 0-3）

## Decision

- LaunchAgent の管理は `server/app_agent.go` に集約した。
  - plist 生成は純粋関数 `generateLaunchAgentPlist(executablePath, userDataPath) string`
    にした（ファイルI/O・launchctl呼び出しを一切含まない）。`Label`/
    `ProgramArguments=[<実行ファイルパス>, --serve]`/`RunAtLoad=true`/
    `KeepAlive=true`/`StandardOutPath`・`StandardErrorPath`
    （`internal/config.GetUserDataPath()/logs/serve.log`・`serve.err.log`）
    を持つ。テストは文字列に期待するフィールドが含まれるかだけを検証する。
  - 設置先は固定で `~/Library/LaunchAgents/com.uxmusic.serve.plist`
    （`launchAgentPlistPath()`、`os.UserHomeDir()` 経由。テストは `$HOME`
    を一時ディレクトリに差し替えて実ホームを汚さない）。
  - launchctl 実行は `launchAgentRunner` インタフェース
    （`Bootstrap(uid, plistPath)` / `Bootout(uid, label)`）の背後に置き、
    本番は `execLaunchAgentRunner`（`exec.Command("launchctl", ...)`）、
    テストは `stubLaunchAgentRunner`（呼び出し引数を記録するだけ）に
    差し替える。パッケージ変数 `currentLaunchAgentRunner` がこの唯一の
    差し替え口。**このリポジトリの自動テストは実行環境上で本物の
    launchctl・実ポート8765に一切触れない**（このマシンの実GUIアプリが
    8765を握っているため、テストで誤って干渉すると実害が出る）。
  - `--install-agent` / `--uninstall-agent` は `server/app_sync_cli.go`
    の `RunSyncCLI` に追加。install は plist 書き出し→bootstrap、
    uninstall は bootout→plist削除（plist が既に無くても bootout 自体は
    必ず試みる。エラーではなく「削除済みの後始末」として許容）。

- GUI 側のハンドオフは `server/app_handoff.go` に実装。
  - `performGUIHandoff(baseURL string) bool` は `App.Startup`
    （`server/app.go`、`StartLANServer` 呼び出し**前**）から呼ぶ。
    引数はテストが httptest サーバの URL を渡せるようパッケージ変数
    `handoffProbeBaseURL`（本番は `http://127.0.0.1:8765`）経由で渡す。
  - 手順: `GET /v1/identity` を照会 →
    - 応答なし（bind前で誰もいない）: 何もせず `false`。
    - `roles` に `"gui"` を含む（別の GUI インスタンスが実行中 — この
      マシンの実機がまさにこのケース）: **テイクオーバーしない**。
      警告ログを出して `false` を返す。この後 `StartLANServer` の
      `ListenAndServe` が bind に失敗するが、既存実装
      （`server/app_remote.go` L54-56）がエラーをログに出すだけで
      非致命的に処理する作りになっていることを確認済み（今回の実装で
      新たに保証を追加する必要はなかった）。
    - `roles` に `"headless"` を含む（常駐 `--serve` インスタンス）:
      `currentLaunchAgentRunner.Bootout` で停止を試み、失敗したら
      `POST /v1/local/shutdown`（`server/app_local.go` の既存フォール
      バック経路）にフォールバック。その後 `waitForPortFree` で
      `/v1/identity` が応答しなくなるかタイムアウト（10秒、100ms間隔）
      まで待ってから `true` を返す。
  - `App.bootedOutResidentAgent`（`server/app.go` の App 構造体に追加）
    に `performGUIHandoff` の戻り値を記録し、`App.Shutdown`
    （`server/app_special.go`）で `true` なら
    `currentLaunchAgentRunner.Bootstrap` を呼んで常駐側を復帰させる。

## Alternatives considered

- **launchctl 呼び出しを `os/exec` 直呼びのまま各所に書く案**: テストが
  実 launchctl を叩かずに済ませられなくなるため却下。インタフェース化
  してテスト時は完全に差し替える構成にした。
- **ハンドオフ判定を mDNS TXT の roles で行う案**: Phase 0-2 の決定
  （`progress/serve-headless-mode.md`）により mDNS TXT の `roles` は
  既存ピア互換のため変更しない方針。`/v1/identity` の JSON `roles`
  （`headless`/`gui`）だけで判定する既存の非対称設計を踏襲した。
- **`kill`/`SIGTERM` で常駐プロセスを止める案**: 計画書が明示的に
  「KeepAlive との競合を避けるため kill ではなく launchctl 経由」と
  指定しており、bootout せずに単純killするとKeepAliveが即座に再起動
  させてしまうため不採用。

## Constraints / Gotchas

- **クラッシュケース**: GUI が `bootedOutResidentAgent=true` の状態で
  クラッシュ終了すると `Shutdown` が呼ばれず、常駐エージェントは
  bootout されたままになる（`KeepAlive` はプロセスが登録されていない
  ので発動しない）。復旧は「次回 GUI 起動時」または「再ログイン時
  （`RunAtLoad=true` により launchd がログイン時に自動起動）」を待つ
  仕様として明記する。自動リカバリは実装していない（計画書の受け入れ
  基準がこの2経路での復旧を前提としているため、スコープ外とした）。
- **別 GUI が実行中のケースの非テイクオーバー方針**: `roles` に `"gui"`
  が含まれる場合は本実装では一切手を出さない。理由は実運用上
  「2台目の GUI がすでに動いている1台目を停止させる」動作は事故の元
  （ユーザーの意図しないデータ経路切断）であり、計画書にも明記が
  ないため保守的に倒した。この場合 LAN サーバは起動できない
  （`StartLANServer` の bind 失敗ログのみ）が、GUI 自体は起動を続ける。
- **開発機での検証について**: このマシンには実機の `UX-Music.app`
  GUI インスタンスが起動しポート8765を握っているため、本 Phase の
  自動テストは httptest と launchAgentRunner スタブのみで完結させて
  おり、実 launchctl・実ポート8765への接続は一切行っていない
  （`go test ./server/...` 実行時にも影響を与えない）。
