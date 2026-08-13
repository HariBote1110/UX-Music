# tvOS 再生パイプラインの並行性構造 監査

## 背景
「かなりの頻度でUIがハングする」というユーザー報告を受け、スポット修正済み（engine data race
クラッシュ、`engineQueue.sync` デッドロック、stale-session 症状）の先を、構造レベルで洗い出す。
直近のコミット（`d3fc7f1` ほか）で最も危険な同期パスはすでに手当て済みだったため、本監査は
「まだ残っている境界越えの同期呼び出し」に焦点を当てる。

## Ownership / Queue マップ

| コンポーネント | 隔離 | 所有するもの |
| :--- | :--- | :--- |
| `TVPlaybackController` | `@MainActor` | 再生プラン選択、`streamState`/`connectionState`、progress mirror `Task` |
| `TVSongStreamController` | `@MainActor` | 単曲ストリーム（cache miss）の `TVRelayStreamPlayer` インスタンスと state machine |
| `TVRelayPlaybackController` | `@MainActor` | 中継（YouTube relay）の `TVRelayStreamPlayer` インスタンスと state machine |
| `TVRelayStreamPlayer` | 独自 `engineQueue`（`DispatchQueue`）+ `generationLock`（`NSLock`） | `AVAudioEngine`/`AVAudioPlayerNode`/`ADTSFrameParser`/`TVAACDecoder`/`isEngineConnected` |
| `TVRelayModel` | `@MainActor` | 5秒ポーリング `Task`（`refreshState`） |
| `TVPlaybackCacheStore` | `actor` | ディスクI/O、LRUアカウンティング、pinned `FileHandle` |
| `MusicPlayerService` | `@MainActor` | ローカル再生用 `AVAudioEngine`、Now Playing、`externalPlaybackCommandHandler` ブリッジ |
| `URLSessionDataDelegate`（`TVRelayStreamPlayer` 内） | セッションのデリゲートキュー（バックグラウンド） | `didReceive data:` → `engineQueue.async` へディスパッチ |

`TVRelayStreamPlayer` が唯一「MainActor でも `engineQueue` でもない」実行コンテキストから
呼ばれる型で、境界越えのほぼ全てがここに集中している。

## 境界を越える同期呼び出し・ロック（全件）

1. **`TVRelayStreamPlayer.elapsedSeconds`**（MainActor → `engineQueue.sync`）
   `TVPlaybackController.progressMirrorTask`（250ms間隔）と `TVSongStreamController.elapsedSeconds`
   から MainActor 上で毎回呼ばれる。`engineQueue` が `didReceive data:` の処理（decode + schedule）で
   混雑していると、その間 MainActor がブロックされる。処理内容自体は軽量だが、フレーム決定的に
   長時間化する保証はない。
2. **`TVRelayStreamPlayer.pause()` / `resume()`**（MainActor → `engineQueue.sync`）
   `TVSongStreamController.togglePlayPause()` から呼ばれる。ユーザー操作起点なので頻度は低いが、
   同じ理由で MainActor をブロックしうる。
3. **`generationLock`（`NSLock`）**（`TVRelayStreamPlayer._generation` の getter/`bumpGeneration()`）
   MainActor（`start()`/`stop()`）とデリゲートキュー（`didReceive data:` 内の `self.generation` 読取）
   の両方から取得される。ロック保持期間は極小なので単体ではデッドロック要因になりにくいが、
   「MainActor が明示ロックを取得する」という設計そのものが今回のターゲットアーキテクチャ
   （後述）が禁止したいパターン。
4. **`MusicPlayerService.dispatchToMainSync`**（`DispatchQueue.main.sync`）
   `MPRemoteCommandCenter` のハンドラ（ロックスクリーン/AirPlay 等からの外部コマンド、
   MainActor 以外の私有キューで呼ばれる）専用。`Thread.isMainThread` ガードがあるため
   MainActor からの自己再入では発生しないが、システムコマンドキューが MainActor の完了を
   同期的に待つ設計そのものは残存する境界越え同期。
5. **`activateSessionIfNeededSync` の `sessionActivationLock`（`NSLock`）**
   `MusicPlayerService` 内、複数の任意キュー（remote command / seek）から取得されうる。

過去に実際にクラッシュ/デッドロックを起こしていた `engine.connect`/`detach` の
`engineQueue.sync` 呼び出し（`start()`/`stop()`）は、コメントにある通り既に `.async` へ
変更済み（`progress/tvos-playback.md` 「engineQueue↔MainActor デッドロック」参照）。
今回の監査で新たに見つかった残存パターンは上記 1〜3 で、いずれも「MainActor が
`engineQueue` に対して同期的に踏み込む」形。

## ハング候補（危険度順）

| 順位 | 箇所 | 根拠 |
| :--- | :--- | :--- |
| 1 | `elapsedSeconds` の `engineQueue.sync`（250ms ポーリングから毎回） | 発生頻度が最も高い。`engineQueue` 側の処理（decode ループ、`schedule` の PCM 展開）が
何らかの理由で伸びた瞬間に UI スレッドが直接引きずられる。ユーザー体感の「頻繁なハング」に
最も一致する候補。 |
| 2 | `pause()`/`resume()` の `engineQueue.sync` | 頻度は低いが、ユーザー操作（再生/一時停止ボタン）の
まさにその瞬間に MainActor をブロックしうるため体感インパクトは大きい。 |
| 3 | `generationLock` の MainActor 側取得 | 現状は保持時間が短くデッドロックはしないが、
「MainActor が session 側のロックに触れる」設計自体が将来の変更で容易に壊れる／再発しうる。 |
| 4 | `dispatchToMainSync` | `Thread.isMainThread` ガードにより自己デッドロックはしないが、
外部コマンドキューが MainActor の作業完了を同期待ちする構造は温存されている。 |

## 対応方針（今回のスコープ）

フルスケールの「単一 actor がセッションを排他的に所有する」再構築（`StreamSession` actor へ
`TVRelayStreamPlayer`+`TVSongStreamController`+`TVRelayPlaybackController` を統合し、
relay/stream 両パスを共通化）は、`MusicPlayerService` 側との結合や既存 114+ テストの
移行コストを踏まえると一度の変更で安全に検証しきれる規模を超える。本セッションでは
危険度1位・2位（MainActor→`engineQueue.sync`）を解消し、「MainActor から session への
同期呼び出み禁止」という不変条件を該当箇所で満たす形にする：

- `elapsedSeconds` は `engineQueue` 内で更新される `@Atomic`-相当の直接プロパティ読み取りに変更し、
  ロック/`sync` を使わない一方向の値伝播に変更。
- `pause()`/`resume()` は `engineQueue.async` に変更し、呼び出し側は fire-and-forget にする
  （`isPaused` のトグルは呼び出し側の楽観更新のまま、UI状態と実際のノード状態がズレても
  次のトグルで整合する程度の許容範囲であることを確認済み）。

危険度3位・4位（`generationLock`／`dispatchToMainSync`）は、上記1・2ほど頻度が高くなく、
今回のスコープでは温存し、将来の `StreamSession` actor 統合時にまとめて解消する
（本ドキュメントの「今後」を参照）。

## 今後（フル actor 統合をやる場合の設計メモ）

- `actor StreamSession` が `AVAudioEngine`/`playerNode`/`parser`/`decoder`/`URLSession` を排他所有。
- relay と単曲ストリームは「音声ソースが継続 HTTP か有限 HTTP か」の差でしかないため、
  `StreamSession` にソース抽象（`AsyncStream<Data>` を渡す形）を与えれば同一実装で両対応できる。
- `URLSessionDataDelegate` は `nonisolated` + `Task { await session.feed(data) }` で actor に入る。
- MainActor 側（`TVSongStreamController`/`TVRelayPlaybackController`）は `StreamSession` の
  `AsyncStream<Event>` を購読するだけにし、`elapsedSeconds` のような同期プロパティ読み取りは
  提供しない（最後に observe した値を MainActor 側でキャッシュする一方向設計に置き換える）。
- 不変条件: 「MainActor から session への同期呼び出し禁止」「session 内に GCD キュー/NSLock を
  置かない（actor の直列性のみに依存する）」。

## DEBUG watchdog
今回のスコープでは未実装（Phase 2 のフル actor 統合と合わせて着手するのが妥当と判断）。

## 追記（ストレス回帰スイート・DEBUG watchdog 実装）

順位1〜2の修正（`elapsedSeconds`/`pause()`/`resume()`）が実運用の連打・高頻度切り替えでも
本当にハングしないことを証明するため、`UX-Music-TVTests/TVPlaybackStressTests.swift` を追加した。
すべて `XCTestExpectation` ベースのハードタイムアウト（`runWithHardTimeout`）で包み、ハングした
場合はテスト自体が「期待値未充足」で FAIL する（スイート全体を巻き込んで停止することはない）。

### スイート構成
1. `testFiftyRapidPlaySwitchCyclesAlternatingStreamAndCachedEndsOnLastRequestedSong` — キャッシュ
   ミス（ストリーム強制）曲とキャッシュヒットに転じる曲を交互に、待機なしで50回連続 `play()`。
   最終セッションが直近リクエスト曲を再生していることのみを検証（到達すること自体が回帰シグナル）。
2. `testStopWhileChunksArrivingThenImmediateRestartTwentyTimesDoesNotHang` — `TVRelayStreamPlayer`
   単体に対し、ジッターバッファ（0.75秒）を満たす前に `stop()` → 即 `start()` を20回連打し、
   最後に1セッションを完走させて健全性を確認。
3. `testPauseResumeIdentityAfterFiveConsecutiveSwitchesAffectsCurrentSongOnly` — 5連続曲切り替え後の
   pause/resume が直近セッションのみに作用することを検証（`TVPlaybackControllerStreamSwitchTests`の
   1回切り替え版を5回に拡張）。

### 結果（ローカル実行・シミュレータ）
- 3連続 `-only-testing` 実行、すべて PASS（`testFiftyRapid...`約0.3〜0.5秒、
  `testStopWhileChunksArriving...`約0.17秒、`testPauseResumeIdentity...`約0.05〜0.07秒）。
- tvOS フルスイート（119件）・iOS フルスイート（532件、共有コア `TVRelayStreamPlayer.swift` を
  触ったため実行）ともに 0 failed。

### スイートが実際に洗い出した本物のバグ（本番コード側の修正）
`testStopWhileChunksArrivingThenImmediateRestartTwentyTimesDoesNotHang` を最初に実装した際、
最終セッションが `jitterBufferSeconds`（0.75秒）を一度も満たせず10秒タイムアウトで FAIL した。
`TVRelayStreamPlayer.swift` に一時的な診断ログ（`/tmp` へのファイル書き込み、後で全削除）を仕込んで
追跡した結果、監査（順位3「generationLock」）とは別の、実装済みだったはずの stale-chunk 破棄機構
そのもののバグを発見:

- `urlSession(_:dataTask:didReceive:)` で `capturedGeneration = self.generation` を
  **`engineQueue.async` のクロージャの中で** 読んでいた。クロージャ内では代入直後に
  `handle(frames, expectedGeneration: capturedGeneration)` を呼ぶだけで、その間に `generation` が
  変わる余地（サスペンションポイントや別クロージャの割り込み）が存在しない。つまり
  `expectedGeneration == generation` は常に自明に真になり、「stale chunk を捨てる」というコメントの
  意図に反して実質何も判定していなかった。
- さらに、`parser.feed(data)` はこの（無意味な）判定より前に無条件で実行されていた。`parser` は
  セッションごとではなく `TVRelayStreamPlayer` インスタンス共有の単一プロパティなので、stale な
  古いセッションのバイト列が新しいセッションの ADTS フレーム境界検出用パーサに混入し、フレーム
  同期を破壊していた（`handle` 内で最終的に捨てられるフレームが出てきても、その時点で既に
  `parser` のバイトストリーム状態は壊れている）。

修正: `capturedGeneration` を **delegate queue 上、`engineQueue.async` にディスパッチする前**に
読むよう変更し、かつ `parser.feed(data)` の直前に `capturedGeneration == self.generation` の
再チェックを追加（`parser` に触れる前に stale chunk を完全に捨てる）。20連打ストレスという
極端な条件でなければ表面化しない不変条件違反だった。

### テストハーネス側で踏んだ落とし穴（記録として）
上記の本番修正後もテスト2は同じ10秒タイムアウトで FAIL し続けた。診断ログで確認すると
`TVRelayStreamPlayer` 自体は正常に最後まで完走（`bufferedSeconds` がジッター閾値を大幅に超えて
最後まで到達、デコードエラーなし）していたが、`relayStreamPlayerDidStartRendering` の
`DispatchQueue.main.async` コールバックだけが待機中ずっと配送されなかった。原因はテスト側:
`XCTWaiter().wait(for:timeout:)`（`TVRelayStreamPlayerLifecycleTests` の `RenderRecorder.wait` を
そのまま踏襲）を `@MainActor` の `Task` 内部から同期的に呼んでいたため、`DispatchQueue.main` の
キューが実際にドレインされる機会が得られなかった（伝統的な同期 `XCTestCase` メソッド直下で
呼ぶ場合とは実行コンテキストが異なる）。`TVPlaybackControllerStreamSwitchTests` の
`waitUntilStreaming` と同じ「`await Task.sleep` によるポーリング」に置き換えて解消した。
以後、`@MainActor` の `Task` 内から `TVRelayStreamPlayerDelegate` 系コールバックを待つ新規テストは
ブロッキング `XCTWaiter().wait` ではなく非同期ポーリングを使うこと。

## DEBUG watchdog（実装済み）
`UX-Music-TV/MainThreadWatchdog.swift`（DEBUG専用）を追加し、`UXMusicTVApp.init()` から起動。
バックグラウンドの `DispatchSourceTimer` が0.5秒おきに `DispatchQueue.main` へ ping を送り、
直前の ping が2秒以内にサービスされなければ `[MainThreadWatchdog] main thread blocked >2.0s
(blocked for X.XXs)` を一度だけログ（`logSink`、DEBUGビルドは `NSLog`、テストは注入差し替え可能）。
`Thread.callStackSymbols` は呼び出し元スレッド自身のスタックしか取れない（他スレッドのスタックを
外部から取得する公開APIがない）ため、実機で本当のスタックが欲しい場合は、このログ行が出た
タイムスタンプを手がかりに `lldb`（`bt` on thread 1）やハングレポートを併用する運用を想定。
実機ログで `[MainThreadWatchdog]` を検索すればハング発生箇所・発生時刻の当たりが付けられる。
ユニットテスト（`MainThreadWatchdogTests.swift`）は実際に `DispatchQueue.main.sync` でメインスレッド
をブロックし、注入した `logSink` にログが届くことを検証している。
