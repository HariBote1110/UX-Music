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

## リモート起点再生時のPCローカル無音化（追記）

リモートから `play-song` で開始した再生は、PC自体のスピーカーからは音を出さない。LAN 中継（`server/app_remote_relay_notify.go` のリレー用タップ）は無関係に動作を継続する。ローカルでユーザーがPC上で再生を開始したときは従来どおり聴こえる。

### 音声パイプラインの調査結果

- **ローカルファイル再生**: `AudioPlay` → `pkg/audio.Player.Play` → デコーダーがリングバッファに書き込み → `processAudio`（PortAudioコールバック）がリングバッファを読み、volume/baseGain/EQ を適用して出力バッファへ書く。
- **YouTube公式埋め込み再生**: `AudioStartWebViewTap` が自プロセスが所有する WebKit ヘルパー PID を対象に Core Audio process tap を張る（`pkg/audio.StartProcessTap`）。**tap は `CATapMutedWhenTapped` 相当でタップ対象プロセスをソース側で常時ミュートする**ため、WebView自体はハードウェアへ直接出力しない。捕捲したPCMは `Player.PlayProcessTap` → `playLiveSource` によって**Goが同じ `processAudio` パイプラインへ再レンダリング**する（EQ/FFT/volumeも通常再生と同じ経路）。つまり通常時の埋め込み再生の可聴化は「タップがソースをミュートし、Goが唯一の音源として再レンダリングする」ことで成立している。
- **LAN中継**: `server/app_remote_relay_notify.go` の `startRelayTap` が **ローカル再生のタップとは別個に**、同じ WebKit ヘルパー PID を対象とするもう一つの `ProcessTapCapture` を張り（`relayStartProcessTap`）、`server/app_remote_relay_source.go` の `processTapRelaySource` 経由で ffmpeg エンコード → `/v1/remote/relay` へ供給する。ローカル再生用タップとは完全に独立したキャプチャ・パイプラインであるため、ローカル出力をどう変更しても中継には影響しない。

### 採用した無音化メカニズム

ローカルファイル・YouTube埋め込みのどちらも、最終的な可聴出力は `pkg/audio.Player.processAudio` の1箇所に収束する（埋め込みはGoが再レンダリングしているため）。そこでこの1箇所に **`Player.localMuted`（`atomic.Bool`）** を追加し、`SetLocalMuted(true)` の間は `processAudio` が出力サンプルを0にする。リングバッファの消費・再生位置(`position`)の進行・EQ/FFT計算はミュート中も止めない（進行状態や後続のトラック管理を壊さないため）。

- ローカルファイル: `Player.Play` 自体は変更せず、`AudioPlay`（`server/app_audio.go`）が再生開始後に `SetLocalMuted` を呼ぶラッパーとして機能する。
- YouTube埋め込み: `AudioStartWebViewTap` が `PlayProcessTap` 開始後に同じく `SetLocalMuted` を呼ぶ。タップ自体（ソース側ミュート）は常時有効のままで変更していない — ここで止めているのは「Goによる再レンダリング後の出力」のみ。
- 中継用タップ（`relayStartProcessTap`）は一切変更していない。

### 起点（remote-initiated）の追跡

`server/app.go` の `App.remoteInitiatedNext`（`atomic.Bool`）が「次の1回の `AudioPlay`/`AudioStartWebViewTap` はリモート起点である」という一度きりのマーカーを保持する。

- `MarkNextPlaybackRemoteInitiated()`（`server/app_audio.go`, Wails公開）がマーカーを立てる。呼び出し元はレンダラーの `handleRemotePlaySongEvent`（`src/renderer/js/features/playback-manager.ts`）で、`playSong()` を呼ぶ直前に必ず呼ぶ。
- `AudioPlay`/`AudioStartWebViewTap` は開始時に `consumeRemoteInitiatedNext()` で読み取り＆即リセットする（`atomic.Bool.Swap(false)`）。マーカーが立っていれば `SetLocalMuted(true)`、立っていなければ（＝通常のローカル再生）`SetLocalMuted(false)` を呼ぶ。
- Go側にフラグを置いた理由: 実際にPCスピーカーの可聴/無音を決めているのは `pkg/audio.Player` であり、レンダラー側の状態だけを変えても音声パイプラインには届かない。レンダラーは「次の再生がリモート起点である」という**意図**を1回だけGoへ伝える薄い仲介役に留めた。

### ミュート解除（unmute）のトリガー

- **解除される**: `AudioPlay` または `AudioStartWebViewTap` が呼ばれ、かつ直前に `MarkNextPlaybackRemoteInitiated` が呼ばれていない場合。これは「ユーザーがPC上で別の曲をクリックする」「『すべて再生』を押す」など、ローカル操作で新規に再生を開始するケース全てに当てはまる（`playSong()` は結局これらのGo APIのどちらかを呼ぶため）。
- **解除されない（意図的なスコープ限定）**: `AudioResume`/`AudioPause`（PCの再生/一時停止ボタン、`src/renderer/js/features/player.ts` の `playCurrent`/`togglePlayPause`）は、`POST /v1/remote/command` の `action: "play"/"pause"/"toggle"` からも**まったく同じGoメソッドが直接呼ばれる**（`server/app_remote.go` の `remoteCommandHandler`、レンダラーを経由しない）。そのため `AudioResume`/`AudioPause` 自体の呼び出しだけでは「ローカル操作か、リモートからの一時停止/再開コマンドか」を区別できない。今回はこの区別のための追加の配線（例: Wails公開メソッドを別名にして分岐する等）は行わず、**ミュート状態の変更は再生の新規開始（`AudioPlay`/`AudioStartWebViewTap`）に限定**した。したがって「リモート起点で再生を開始した曲を、PC側で一時停止→再開した」場合はミュートされたままとなる。ユーザーが本当に聴きたいなら、ローカルでその曲（または別の曲）を選び直せば解除される。

### 状態の公開

`GET /v1/remote/state` のレスポンスに `"localMuted": bool` を追加（`server/app_remote.go`）。既存フィールドは変更していないので、キーを知らないクライアントには影響しない。

### テスト

- `pkg/audio/player_mute_test.go`: `Player{}` を直接構築し `processAudio` を叩くユニットテスト。ミュート時に出力が0になること、リングバッファの消費と再生位置の進行はミュート中も止まらないことを検証（Core Audio 実機は使わない）。
- `server/app_audio_mute_test.go`: `App{}` 直接構築で `consumeRemoteInitiatedNext` が一度きりであること、`AudioIsLocalMuted()` が `audioPlayer == nil` でも安全に `false` を返すことを検証。
- `src/renderer/js/features/playback-manager.test.ts`: `handleRemotePlaySongEvent` が `playResolvedSong` の前に `markRemoteInitiated` を1回だけ呼ぶことを検証。

### 実機でしか確認できない残項目（手動確認が必要）

- 実際に Core Audio process tap が張られた macOS 実機上で、リモート起点のYouTube埋め込み再生中に **PCのスピーカーから本当に無音になり**、かつ **同時に別デバイス（TV/モバイル）側でLAN中継の音声が途切れず聴こえる**ことの確認。本セッションではユーザーの実アプリ（ポート8765で稼働中）への接続やスピーカー出力は禁止されていたため、この統合的な可聴確認はユニットテストでは代替できていない。
