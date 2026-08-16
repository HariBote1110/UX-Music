# embed再生中のposition/duration/playingを/v1/remote/stateへ反映

## Decision
- YouTube公式embed再生中はGoの`audio.Player`がアイドル（position/duration/
  playingが常に0/0/false相当）で、実際に鳴っているのはレンダラーのIFrame
  プレイヤーであるため、TVのシークUIが機能しない問題があった。
- 新設Wailsバインド `ReportEmbedPlaybackState(position, duration, playing)`
  （`server/app_remote_embed_state.go`）をレンダラー
  （`src/renderer/js/features/player.ts`の`startGoStatePolling`が既に
  embed再生中は`embedGetCurrentTime`/`embedGetDuration`/`embedIsPlaying`を
  約1秒間隔で読んでいたポーリングtickに相乗り）から呼び、Go側の
  `currentEmbedPlaybackReport`（プロセス内シングルトン、`remoteRelay`と
  同じ設計方針）へ書き込む。加えて `playCurrent`/`pauseCurrent`/`seek`の
  embed分岐でも即時報告し、pause/seek直後の反映遅延を減らした。
- `remoteStateHandler`は `embedSessionActive()`（`remoteRelay.active`流用）
  かつ報告済み（`active`フラグ）のときだけ、root直下の`position`/
  `duration`/`playing`/`paused`を上書きする。加算的な変更で、報告が一度も
  無い間やembedセッション非アクティブ時は既存の`AudioGetStatus()`由来の値
  がそのまま返る。
- embedセッション終了（`NotifyYouTubePlaybackState(false, ...)`)時に
  `currentEmbedPlaybackReport.Clear()`を呼び、次に始まるGoプレイヤー
  （ローカルファイル）再生のstateへ前の曲の位置が漏れないようにした。
- 見つかったseek単位の整合性: `POST /v1/remote/command`の`seek`アクション
  はembedセッション中`remote-embed-command`イベントへ委譲され、レンダラー
  `youtube-embed-bridge.ts`の`buildEmbedCommand('seek', seconds)`→
  `youtube-embed-player.ts`の`embedSeekTo(seconds)`まで一貫して秒単位。
  Goの`AudioSeek`（ローカル再生時）も同じく秒単位。ズレは無く、修正不要と
  確認した。

## Alternatives considered
- レンダラーからGoへ都度push（今回採用）ではなく、GoがWails経由でレンダラー
  へ能動的にpull（例: `runtime.EventsEmit`のリクエスト/応答）する案:
  却下。既存のポーリングtickに相乗りする方がシンプルで、Wailsイベントの
  往復を新設する必要がない。
- `remoteRelay`自体に position/duration を持たせる案: 却下。`relayEngine`
  はPCM→ADTSエンコードのブロードキャスト機構であり、再生位置というプレイ
  ヤー状態を持たせるのは責務が異なる。独立した`embedPlaybackReport`型に
  分離した。

## Constraints / Gotchas
- `currentEmbedPlaybackReport`はプロセス内グローバル（`remoteRelay`と同じ
  理由: プロセスあたり高々1つのデスクトップ再生パイプライン）。テストでは
  同一パッケージ内であることを利用し `remoteRelay.active` を直接書き換える
  `setRelayActiveForTest`ヘルパーで実ffmpeg無しに`embedSessionActive()`を
  制御している（`server/app_remote_embed_state_test.go`）。
- ヘッドレスモードでは`ReportEmbedPlaybackState`は安全なno-op
  （`NotifyYouTubePlaybackState`と同じモードゲート方針）。
