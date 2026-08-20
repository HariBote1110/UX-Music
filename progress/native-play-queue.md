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

## 並行安全性（レビュー対応・増分2）

`pkg/playqueue.Queue` は当初 `sync.Mutex` を持たずに実装したが、実際の呼び出し元は
複数 goroutine にまたがる: Wails バインディング（QueueSet/Next/Prev/Jump/
SetShuffle/SetLoopMode/GetState）、`audio.Player` の `OnFinished` コールバック
（再生・デコーダ goroutine から発火）、LAN リモートコマンドの HTTP ハンドラー
（リクエストごとに goroutine）、OS メディアキーのコールバック。レビューで
指摘を受け、`go test -race` でデータレースを検出するテスト
（`pkg/playqueue/queue_race_test.go`）を先に追加して再現を確認したうえで、
`Queue` に `sync.Mutex` を追加し全メソッドをロックするようにした。

- `sync.Mutex` は再入不可のため、`Advance`/`Previous`/`JumpTo`/`SetShuffle` の
  内部から現在項目を読む箇所は、ロックを取らない `currentItemLocked`
  （`CurrentItem` の実体）を呼ぶよう分離した。ロック済みメソッドから
  `CurrentItem()`（ロックを取る方）を呼ぶとデッドロックするため注意。
- `go test -race ./pkg/playqueue/... ./server/...` で確認済み（後者は
  `server/app_queue.go` 経由の配線側にレースが無いことの確認）。

## 自動進行の失敗時スキップ（レビュー対応・増分2）

当初の `handlePlaybackFinished` は、自動進行で次の項目の再生開始
（`startQueueItem`）が失敗すると、ログを出すだけで何もせず終わっていた
（例: キュー内の曲のファイルが再生中に削除されていた場合、無音のまま
停止する）。レビュー指摘を受け、失敗した項目をスキップして次を試すよう
`autoAdvanceQueue`（`handlePlaybackFinished` から分離）に変更した。

- **上限はキューの項目数（1周分）**。`Advance()` 単体は前進を保証しない
  （`LoopAll` は末尾から index 0 へ戻るだけ、`LoopOne` は現在位置から
  一切動かない）ため、上限が無いと全項目が再生失敗するケース
  （例: 参照ファイルが軒並み削除された）で無限リトライしうる。上限に
  達したら `AudioStop` して諦める。`LoopOne` の場合は同じ項目を上限回数
  まで再試行する形になる（どの項目を既に試したかまでは追跡しない、
  意図的な簡略化）。
- **この挙動が適用されるのは自動進行（`OnFinished` 経由）のみ**。
  `QueueNext`/`QueuePrev`/`QueueJump`/`QueueSet` のような明示操作
  （ユーザー操作・リモートコマンド・OS メディアキー由来）は従来どおり、
  要求された1項目の失敗だけをそのまま呼び出し元へ返し、キューは
  その項目の位置に留まる（勝手に別の曲へは進まない）。
- テスト用の差し替えシームとして `App.queueItemStarter`
  （`func(playqueue.Item) error`、既定 nil）を追加し、実際の
  `audioPlayer`/ネットワークに触れない fake starter で
  「途中失敗をスキップして次で成功」「全滅して上限で諦める」
  「明示操作はスキップしない」の3パターンを決定的に検証した。

## カットオーバー（フロントエンド移管、増分3）

`src/renderer/js/features/playback-manager.ts`（薄い UI/操作層に）と
`player.ts` を、`isWailsMode()` のときだけ Go のネイティブキューへ全面委任
するよう書き換えた。非 Wails のブラウザフォールバックは無改修。

### queue-advanced イベントの新設（Go 側）

移管前提として、`server/app_queue.go` に `queue-advanced`
（`{previousId, reason: "finished"|"user"}`）を追加した。Go がキューを
丸ごと動かすようになると、レンダラーは「自然終了」（player.ts の
イベント発火元）と「ユーザースキップ」を自力では区別できなくなるため
（従来は JS 側の `playNextSong()`/`handleSkip()` と
`audio-playback-finished` ハンドラで呼び分けを実装していた）、Go 側で
判定して明示的に伝える形にした。

- `QueueNext`/`QueuePrev`/`QueueJump`/`QueueSet`（既にアクティブなキューを
  置き換えたとき）は `reason: "user"` で emit する。
  - `QueueJump` にも emit させたのは移管タスクのブリーフ（本コミット群の
    元指示）の明示要求による。JS レガシー版の `playSong(idx)`（再生キュー
    サイドバーのクリック、`sourceList` なし）は `handleSkip()` を呼んで
    おらず、厳密移植ならここは emit しない方が JS 挙動に忠実だった —
    **意図的な相違点**として記録する。実害は「キュー項目クリックでも
    analysed-queue のスキップスコアが付くようになる」程度。
  - `LoopOne` での `QueueNext`（同じ曲を先頭から再生し直す）でも emit する
    （JS 版の `playNextSong()` が LOOP_ONE でも `handleSkip()` を無条件に
    呼んでいたのに合わせた、これは厳密な JS 互換）。
- 自動進行（`OnFinished` 経由の `autoAdvanceQueue`）は `reason: "finished"`
  で、スキップ再試行が絡んでも「実際に鳴っていた曲」1件についてのみ
  1回だけ emit する。
- YouTube 公式 embed は Go 自身が再生を検知できない（`startQueueItem` の
  embed 経路は `queue-play-embed` を emit して即 return するだけ）ため、
  レンダラーが IFrame の自然終了を検知したときに呼ぶ
  `QueueAdvanceFinished()` を新設した。内部は `autoAdvanceQueue` をそのまま
  再利用し、embed 曲でも `reason: "finished"` を維持する
  （`QueueNext()` を代用すると `reason: "user"` になってスコアリングが
  誤ってスキップ扱いになるため、専用バインディングにした）。

### フロントエンド側の配線

- **`playSong(index, sourceList, forcePlay)`**: Wails 時は
  `runPlaySongWorkWails` に分岐する。`sourceList` があれば
  `QueueSet(sourceList, index)`（新しいキューを始める＝曲一覧・アルバム
  全曲再生など）、なければ `QueueJump(index)`（既存キュー内のジャンプ＝
  再生キューサイドバーのクリックなど）。UX Sync のリモート曲（ローカル
  未取得）だけは Go に判断できないため、従来どおりここで先に
  ダウンロード解決してから渡す。`forcePlay`（ラウドネス解析待ちの JS
  概念）は Go 側に対応する待ち合わせが無いため使わない。
- **`playNextSong`/`playPrevSong`**: Wails 時はそれぞれ `QueueNext()`/
  `QueuePrev()` を呼ぶだけ。JS 側キューの直接操作（`handleSkip()` 含む）
  は行わない — スキップのスコアリングは `queue-advanced` 経由に一本化。
- **`toggleShuffle`/`toggleLoopMode`**: Wails 時は次の値を計算して
  `QueueSetShuffle`/`QueueSetLoopMode` を呼ぶ（ループモードの JS⇔Go
  表記変換は `queue-bridge.ts` の `toGoLoopMode`/`fromGoLoopMode`）。
  押した瞬間の手応えのため、ボタンの見た目だけは即時にも更新する
  （`queue-state-changed` で確定反映されるので二重更新だが冪等）。
  シャッフル/ループの設定は引き続き `musicApi.saveSettings` で永続化し、
  起動時（`initPlaybackSettings`）に Go の（プロセスごとに空の）キューへ
  種付けし直す。
- **`"queue-state-changed"` → `handleQueueStateChangedEvent`**: payload を
  `queue-bridge.ts` の `mapQueueSnapshotToQueueState` で
  `state.playbackQueue`/`currentSongIndex`/`isShuffled`/`playbackMode` へ
  写像し、既存の UI 描画関数（`ui-manager.ts` の
  `updatePlayingIndicators`/`renderQueueView`、`now-playing.ts` の
  `updateNowPlayingView` 等）をそのまま再利用する。Go が唯一の真実源に
  なったので、このファイルは「表示するだけ」。`payload.active` は
  `player.ts` の `setGoQueueActive` に伝え、embed の自然終了ハンドラが
  Go 主導かどうかを判別できるようにする。`prefetchUpcomingRemoteTracks`
  もここから駆動する（従来は `playSong` 成功後に呼んでいた）。
  キュー項目はライブラリ照合（`getSongById`）でフルの `Song` に復元する
  （`hydrateQueueItem`）— Go の queue item は最小限のフィールドしか
  持たないため。
- **`"queue-advanced"` → `handleQueueAdvancedEvent`**: `reason` に応じて
  `musicApi.songFinished`/`songSkipped` を呼び分ける。`"user"` は
  `shouldRecordQueueAdvancedSkip`（`currentTime > 0 && duration > 0`、
  `player.ts` がポーリングでキャッシュしている値を使う）でレガシー版の
  `buildSkipEvent` と同等の「途中スキップだけ記録する」ヒューリスティックを
  再現している。
- **`"queue-play-embed"` → `handleQueuePlayEmbedEvent`**: `player.ts` に
  追加した `playQueueEmbedItem`（`play()` の embed 分岐から
  経路判定だけを外したもの）で再生を開始する。**再生回数計上は
  ここが唯一の起点** — Go の `startQueueItem` は embed 経路のときだけ
  `IncrementPlayCount` を呼ばない設計（既存仕様、上の「再生回数の計上と
  二重計上回避」節を参照）なので、`playQueueEmbedItem` が成功したときだけ
  `musicApi.playbackStarted` を呼ぶ。
- **embed の自然終了**（`player.ts` の `playEmbed` の `onEnded`）: Go の
  キューがアクティブ（`goQueueActive`）なら `QueueAdvanceFinished()` を
  呼んで Go に進行を委ね、非アクティブ（レガシー、Go 移行前の単発 embed
  再生）なら従来どおりレンダラー内で完結させる。
- **起動時同期**: `initPlaybackSettings`（Wails 時のみ）が
  `QueueGetState()` を呼んで初期状態を反映する。Phase 1 の通常起動では
  「まだ何も再生していない」状態が返るだけだが、Phase 2（WebView
  駐機/復帰）で Go のキューがアクティブなまま SPA だけが再読み込みされる
  場面のための復元シームとして先に用意した。

### 二重計上の監査結果

`musicApi.playbackStarted` の呼び出し箇所は最終的に2箇所のみ：
非 Wails レガシー経路（`runPlaySongWork` 内、従来どおり）と
`handleQueuePlayEmbedEvent`（embed 経路、新設）。local/stream は Go の
`incrementPlayCountForQueueItem` が唯一のカウント元で、JS からは一切
呼ばれない。Wails かつ queue アクティブな状態で JS 側が
`playbackStarted` を呼ぶ経路は存在しない。

### wailsjs バインディングスタブ

`wails build`/`wails generate` を実行できない開発環境のため、
`src/renderer/wailsjs/go/server/App.{d.ts,js}` に `QueueSet`/`QueueNext`/
`QueuePrev`/`QueueJump`/`QueueSetShuffle`/`QueueSetLoopMode`/
`QueueGetState`/`QueueAdvanceFinished` のスタブを手動追記した（既存の
自動生成ファイルの命名規則・アルファベット順に合わせた）。実際のアプリ
実行時は `window.go.server.App` に実体が注入されるため動作に支障は
無いが、次回 `wails generate` 実行時に差分が出ないか確認すること。

## 既知の制約・今回やらなかったこと（フロントエンド移管タスクへの申し送り、Phase 2 向け）

- **`playback-manager.ts` はカットオーバー済み**（上の「カットオーバー」節参照）。
  以下はこのカットオーバー後もなお残っている制約。
- **embed セッション中の Go 主導 next/prev**: リモートコマンド・OS メディアキーの
  next/prev はキューが Active なら常に Go 側 `QueueNext`/`QueuePrev` を呼ぶが、
  現在レンダラーの IFrame で embed 再生中であっても、その embed セッションを
  明示的に停止する処理はしていない（embed/relay パイプライン自体は今回のタスク範囲外）。
  次に進む項目が embed なら `queue-play-embed` を emit するだけなので実害は
  レンダラー側の後始末次第（`playQueueEmbedItem` は先頭で `stop()` を呼ぶため、
  古い embed セッションの後始末自体は行われる）。
- **`QueueGetState` は LAN API (`/v1/remote/state`) に未接続**。Wails バインディングと
  `queue-state-changed` イベントのみ。モバイル/Watch 側でキュー状態が要るようになったら
  別途 REST 経由での公開を検討する。
- **ヘッドレス安全性**: `audioPlayer == nil` でも `ensureQueue()`/`QueueSet` 等は
  パニックせずエラーを返すのみ（既存の `AudioPlay` 等と同じ流儀）。`--serve` の
  ヘッドレス起動フロー自体は変更していない。
