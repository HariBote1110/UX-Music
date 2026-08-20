# ネイティブ再生キュー（Phase 1: Go 移管）

`markdown/background-native-queue-plan.md` の Phase 1（キューの Go 移管）実装記録。
Go 側のみ実装し、フロントエンド（`src/renderer/js/features/playback-manager.ts`）
の書き換えは別タスク。

## 決定

- **`pkg/playqueue`** を新設。Wails/PortAudio に一切依存しない純ロジックパッケージとし、
  TDD で JS 版 `playback-manager.ts` の next/prev/shuffle/loop 挙動を移植した。
- **opt-in 設計**: `Queue.Active()` は `SetQueue` が一度も呼ばれるまで `false`。
  `server/app_queue.go` の全ての next/prev 横取り箇所（リモートコマンド・OS メディア
  キー・`OnFinished` フック）は `Active()` を見て分岐し、非アクティブ時は既存の
  レンダラー委譲コードパスを一切変更しない。フロントエンドが未改修の Phase 1 時点では
  `QueueSet` を呼ぶ経路が存在しないため、本番動作への影響はゼロ（配線のみ先行）。

## JS 版との互換性（pkg/playqueue）

`playback-manager.ts` の実装を仕様として次の点を移植した:

- **末尾での next**: `LOOP_ALL` なら index 0 へラップ、それ以外は停止
  （`Advance()` が `ok=false` を返し、現在位置は空になる）。
- **`LOOP_ONE` での next**: 同じ曲を返す（index 不変）。
- **prev はループモード非依存**: `playPrevSong()` は `LOOP_ONE` かどうかを見ずに
  常に 1 つ戻り、index 0 では末尾へラップする。`Previous()` も同様。
- **シャッフル ON**: `originalQueueSource`（非シャッフル順）から現在曲を除いて
  シャッフルし、現在曲を先頭に固定して index=0 にする（`toggleShuffle()` 相当）。
- **シャッフル OFF**: 元の順序（`original`）に戻し、現在曲を ID で探して
  その index に合わせる。見つからなければ空（-1）。
- **シャッフル状態での `SetQueue`**: `playSong()` が `sourceList` を受け取ったときと
  同じく、シャッフル中に新しいキューを渡されたら開始曲を先頭固定で即座に再シャッフルする。

### 意図的な相違点

- **JumpTo 失敗時の巻き戻し**: JS の `playSong()` は再生開始 (`playSongInPlayer`) が
  失敗すると `currentSongIndex` を元に戻すが、`Queue`/`app_queue.go` は失敗しても
  キュー位置を戻さない（要求された項目を指したまま、エラーだけ返す）。
  ヘッドレス（`audioPlayer == nil`）や実機の一時的な再生失敗を過度に複雑化しないための
  簡略化。実運用（デスクトップに必ずプレイヤーがある）では影響が小さいと判断したが、
  フロントエンド移管時に再検討が必要なら要相談。
- **ラウドネス解析待ち（`shouldWaitForAnalysis`）を移植しない**: JS 版は保存済み
  ラウドネス値が無い曲の初回再生を「解析待ち」として一時的に止め、通知を出して
  解析要求を送る。Go 側の自動進行はこの待ち合わせを行わず、値が無ければ
  ゲイン 1.0（無正規化）でそのまま再生する（`resolveQueueLoudnessGain` は
  `forcePlay=true` 相当）。バックグラウンド自動進行を解析完了まで止める設計は
  Phase 1 の Go 単体では作り込まず、フロントエンド移管時に必要なら追加する。

## 再生回数の計上と二重計上回避

調査の結果、実際のコードでは **再生回数の加算は曲の再生開始時**
（`bridge.ts` の `musicApi.playbackStarted` → `App.IncrementPlayCount`）に行われており、
`SongFinished`（`audio-playback-finished` 受信時に呼ばれる）は `analysed-queue` の
スコア調整のみで実際の再生回数には関与しない。計画書の記述（「SongFinished で計上」）は
実装時点のコードと食い違っていたため、コードを正として設計した。

- `startQueueItem` が Go でネイティブ再生を開始するたびに一度だけ
  `IncrementPlayCount`（`incrementPlayCountForQueueItem` 経由、Wails バインディングと
  完全に同じ関数）を呼ぶ。
- `handlePlaybackFinished`（`OnFinished` フック）は、キューが **アクティブなときは
  `audio-playback-finished` を emit しない**。この事象がなければレンダラーの
  `player.ts` リスナーは一切発火せず、`SongFinished`（スコア調整）も呼ばれない。
- Go 主導の自動進行はレンダラーの `playSong()`/`musicApi.playbackStarted` を
  一切経由しないため、「Go が起動した再生」と「JS が起動した再生」が同じ trackで
  重複して `IncrementPlayCount` を呼ぶことは起こり得ない。両者は排他的
  （キューが Active なら常に Go が起動、非 Active なら常に JS が起動）。
- キューが非アクティブなら `audio-playback-finished` は従来どおり emit され、
  挙動は変更前と完全に同じ。

## YouTube 経路解決

`resolveQueueItemRoute`（`server/app_queue.go`）は
`youtube-embed-route.ts` の `resolveYouTubePlaybackRoute` を Go に移植したもの。
`local`/`youtube` の判定と `settings.youtubePlaybackMode` の読み方
（`resolveYoutubePlaybackMode`、未設定時は `"embed"` 既定）を完全に再利用した。

- **stream 経路**: `internal/youtube.GetYouTubeStreamURL` で直接ストリーム URL を
  解決し、`AudioPlay` へそのまま渡す（`pkg/audio.Player.Play` の `isRemoteSource`
  分岐が URL を扱う）。ゲインは JS 版と同じく 1.0 固定（YouTube 経路はローカル曲の
  ラウドネス正規化の対象外）。
- **embed 経路**: Go はプロセスタップで公式 embed を鳴らせない（範囲外）ため、
  `queue-play-embed` イベントを emit してレンダラーに委譲するだけで
  `audioPlayer` には一切触れない。

## 既知の制約・今回やらなかったこと（フロントエンド移管タスクへの申し送り）

- **`playback-manager.ts` は未変更**。`QueueSet` を呼ぶ経路が存在しないため、
  今回追加した Go 側の配線は本番では未使用（次のフェーズで結線される）。
- **embed セッション中の Go 主導 next/prev**: リモートコマンド・OS メディアキーの
  next/prev はキューが Active なら常に Go 側 `QueueNext`/`QueuePrev` を呼ぶが、
  現在レンダラーの IFrame で embed 再生中であっても、その embed セッションを
  明示的に停止する処理はしていない（embed/relay パイプライン自体は今回のタスク範囲外）。
  次に進む項目が embed なら `queue-play-embed` を emit するだけなので実害は
  レンダラー側の後始末次第。フロントエンド移管時に embed セッションのライフサイクルと
  合わせて設計すること。
- **`QueueGetState` は LAN API (`/v1/remote/state`) に未接続**。Wails バインディングと
  `queue-state-changed` イベントのみ。モバイル/Watch 側でキュー状態が要るようになったら
  別途 REST 経由での公開を検討する。
- **ヘッドレス安全性**: `audioPlayer == nil` でも `ensureQueue()`/`QueueSet` 等は
  パニックせずエラーを返すのみ（既存の `AudioPlay` 等と同じ流儀）。`--serve` の
  ヘッドレス起動フロー自体は変更していない。
