# POST /v1/remote/command の action: "play-song"（デスクトップ側）

## Decision

- **エンドポイント**: 既存の `POST /v1/remote/command`（`server/app_remote.go` の `remoteCommandHandler`）に `action: "play-song"` を追加する。新しいエンドポイントは作らず、`toggle`/`play`/`pause`/`stop`/`next`/`prev`/`seek` と同じ入口・同じ認証（`deviceAuthTokens`）を使う。
  - リクエスト: `{"action":"play-song","songId":"<ライブラリの曲id>"}`。
  - `songId` 欠落は 400。未知の `songId`（`remoteLibrarySongByID` で解決できない）は標準の 404 エラー JSON（`{"error":{"code":"not_found",...}}`）。
  - **ヘッドレスモードでは 409 `gui_required`** を返す。再生は Wails のレンダラー（`<audio>` 要素・YouTube 公式埋め込み）に依存しており、`--serve` ヘッドレス起動には Wails ランタイムも WebView も存在しないため、そもそも実行不能。`GET /v1/remote/relay` がヘッドレス時に 404 を返す既存パターンとは異なり、ここでは「クライアントが要求そのものは正しく理解できたが、今のサーバー状態では実行できない」ことを表すため 409 + 専用コード `gui_required` を採用した（`writeAPIErrorWithCode` を新設）。
- **レンダラーへの配送方式（イベント形状の選定）**: 既存の `next`/`prev` は `ls.app.emit("remote-command", cmd.Action)` で **素の文字列**のみを飛ばしている。`play-song` はこれとは別に **新イベント名 `remote-play-song`** で `songId`（文字列）を1つだけ渡す設計にした。
  - 理由: レンダラー側を実際に調査した結果、`"remote-command"` を購読しているコードは（`next`/`prev` の配線を含め）現時点で renderer に存在しなかった（将来配線予定と思われるが未着手）。したがって「既存の受け手が期待する形式」を壊す/拡張する必要は実質なく、後方互換性を保つ最も単純な選択は「文字列イベントはそのまま」「新機能は別イベント」で分離することだった。1つの `"remote-command"` イベントのペイロードを `string | {action, songId}` のユニオン型に変えて分岐させる案より、購読側の型分岐が単純になり、将来 `next`/`prev` の配線が実装されても互換性の懸念が生じない。
  - ペイロードは songId 文字列のみ（構造化オブジェクトにしなかった）。`play-song` が運ぶ情報は songId 一つだけであり、将来フィールドが増える見込みが今のところ無いため、最小のペイロードにした。
- **デスクトップ側の再生経路**: `src/renderer/js/features/playback-manager.ts` に `remote-play-song` の購読 (`initRemotePlaySongListener`、`initPlaybackSettings` から呼び出し) を追加。ハンドラ本体は `handleRemotePlaySongEvent(songId, deps)` として切り出し、`getSongById`（`core/library-model.ts`）でライブラリからidを解決し、見つかれば `playSong(0, [song])` を呼ぶ。
  - `playSong` はユーザーが曲をクリックしたとき（`list-renderer.ts` の `handleSongItemClick`）や「すべて再生」ボタン（`detail-renderer.ts`）が使うのと **同じ関数**。新しい再生ロジックは一切書いていない。ローカル曲はそのまま再生され、YouTube 由来の曲は既存の「公式埋め込みへルーティング → `NotifyYouTubePlaybackState` → LAN 中継起動」という経路にそのまま乗る。
  - 曲が見つからない場合は既存の `showNotification`（トースト）で通知する。

## Alternatives considered

- **`"remote-command"` のペイロードを `string | object` のユニオンにして単一イベントに統合** → 将来 `next`/`prev` の実配線が入ったときに購読側で型分岐が必要になり、かつ現状「壊れる既存購読者」が存在しないため、統合するメリットが薄いと判断し不採用。
- **ヘッドレス時に 404（`GET /v1/remote/relay` と同じ）を返す** → `play-song` はエンドポイント自体は常に存在し、リクエストの意味も理解できる（`action` は既知）。「今は実行できない」という 409 の意味論の方が正確なため、404 ではなく 409 + `gui_required` を採用。
- **songId 解決を `remoteLibrarySongByID` の代わりに独自実装する** → `/v1/remote/lyrics` 等が既に使っている解決関数を再利用し、TV 側専用の別解決ロジックは作らない方針（`remote-play-event.md` と同じ判断）。

## Constraints / Gotchas

- Go 側の httptest はサーバーの実ポート 8765 には一切触れず、`NewLANHTTPHandler(app)` を直接 `httptest.NewRecorder()` に対して叩く（`server/app_remote_play_song_test.go`）。`playCountsEmitter` を差し込んで emit を観測しており、`app_remote_play_event_test.go` と同じパターン。
- `CurrentServerMode()` はパッケージ変数のため、テストは必ず `original := CurrentServerMode(); defer SetServerMode(original)` で元に戻す（既存テストと同じ作法）。
- TV クライアント側（この `play-song` を実際に叩く実装）はスコープ外。将来の TV 実装は `Authorization: Bearer <deviceAuthTokens 経由のトークン>` を付与して呼ぶこと。
