# Electron 時代の死んだコード削除（デスクトップ版レンダラー）

## 決定

- 事前の読み取り専用監査に基づき、Electron→Wails v2 移行後に残っていた到達不能／未実装チャンネルを叩くコードを、1件ずつ Go 側（`server/`・`internal/`・`pkg/`・`cmd/`・`main.go`）と `env-setup.ts` の dispatch テーブルをグレップして生死を再確認したうえで削除した。
  - `list-renderer.ts`: `window.go` が常に定義される Wails 環境専用となり、存在しない `show-song-context-menu` を叩く `else` 分岐（旧 Electron 版のコンテキストメニュー委譲）を削除。副作用として未使用になった `contextView` ローカル変数も整理（呼び出し元との互換性のため型定義には残置）。
  - `player-ui.ts`: `getWailsApp()` が常に truthy な本番環境では到達しない `save-settings` の `electronAPI.send` フォールバックを削除。
  - `player.ts`: 到達不能な `playback-stopped` の `electronAPI.send` 呼び出しを削除。
  - `init-listeners.ts`: `musicApi.startScanPaths` に置き換え済みの `start-scan-paths` コメントアウト行、およびどこからも emit されない `navigate-back` リスナーを削除。
  - `debug-commands.ts`: 未実装の `debug-reset-library` / `debug-rollback-migration` を叩く `uxDebug.resetLibrary()` / `rollbackMigration()` を help 表示ごと削除。
  - `ipc.ts`（死んだリスナー・Go 側に emitter なし）: `app-info-response` / `force-reload-playlist` / `force-reload-library` / `show-loading` / `hide-loading` / `show-error` / `playlist-import-progress` / `playlist-import-finished` / `scan-progress`。
  - `ipc.ts`（実ハンドラと重複していたリスナー）: `load-library` / `settings-loaded` / `play-counts-updated` / `playlists-updated` / `scan-complete` / `artwork-changed` / `album-order-saved` は `renderer.ts` の `electronAPI.on` 直接登録または `musicApi.onXxx`（`bridge.ts`）で実際に処理されている。`youtube-link-processed` は Go 側 (`app_youtube.go`) で `scan-complete` と同時に emit されており、実質的な反映（ライブラリ追加・通知）は `scan-complete` の実ハンドラが担っているため、コールバック未配線の重複リスナーとして同様に削除した。
  - `wails-check.ts`: `checkWails()` 内に残っていた移行期の動作確認コード（「UIに表示するテスト」コメント付き）が `#app-version` の表示末尾へ常に `" (Wails Mode)"` を付与していたため削除。`app.Ping()` の疎通確認自体は console ログとして維持。

- **`initIPC(callbacks)` の callbacks 注入パターンが、死んだリスナーの温床だったという構造的な原因**: `initIPC` は呼び出し元 (`renderer.ts`) から渡された `callbacks.onXxx` を呼ぶだけの薄いラッパーだったため、`renderer.ts` 側が直接 `electronAPI.on`／`musicApi.onXxx` で購読するように移行した後も `ipc.ts` 側の登録だけが取り残され、コールバック未配線のまま静かに no-op 化していた。`initIPC` の `callbacks` は元々 TypeScript の interface 型注釈がないプレーンオブジェクトのため、削除後も `onFlacIndexProgress`/`onFlacIndexComplete`（`renderer.ts` から実際に渡されている唯一のキー）以外に整理すべき型定義は存在しなかった。`initIPC` 自体は上記2件のリスナー登録が生きているため関数として空にはなっていない。

- **`window.electronAPI` は現役の Wails 向けシムである**（`env-setup.ts` 定義、約40箇所から利用）。リネームは意図的に別スコープとして今回は着手していない。

## 検討した代替案

- `ipc.ts` の全リスナーを一括削除する案は採らず、「Go 側に emitter が存在しない（項目7）」と「実ハンドラと重複している（項目8）」を別コミットに分け、後者はチャンネル単位でグレップ確認しながら1件ずつ削除した。理由: 監査結果の分類（項目7 = 完全に死亡、項目8 = 重複）が一部実態とズレていた（`force-reload-playlist` と `app-info-response` は `musicApi.onXxx`／`electronAPI.on` 経由の実ハンドラが別途存在するにもかかわらず項目7に分類されていた）ため、削除前に必ず自分でグレップし直す方針を徹底した。分類のズレ自体は削除の可否に影響しない（どちらのチャンネルも `ipc.ts` 側のコールバックは未配線で no-op だったため）。

## 制約・注意点

- `player.ts` の `if (isWails) … else if (localPlayer) …` 分岐は削除対象外。コメントに "Electron" とあるが `localPlayer` は非 Wails ブラウザ環境向けの正当な HTML5 `<audio>` フォールバックであり、誤解を招くコメントのみ "non-Wails browser fallback" 表記へ修正した（`player.ts` 101-102行付近／337行／481行／495行、および `env-setup.ts` のファイルヘッダーと `[Electron-Mock]` ログラベル）。
- 以下は「人間の判断が必要な機能欠落」であり、今回は意図的に一切手を付けていない（監査結果の一部として誤って死んだコード扱いされないよう明記）:
  - `init-listeners.ts` の `show-general-context-menu` / `import-youtube-playlist`
  - `now-playing.ts` の `open-external-link`
  - `audio-graph.ts` の `direct-link-command`
  - `playback-manager.ts` の `request-bpm-analysis`
  - `ui-manager.ts` の `save-migrated-data`
  - `ipc.ts` の `request-new-playlist-with-songs` / `show-edit-metadata-modal`（および前者内の `create-new-playlist-with-songs` send）
- `Electron_Based_UX-Music/` ディレクトリ、`dist/`、`src/common/` には一切触れていない。
