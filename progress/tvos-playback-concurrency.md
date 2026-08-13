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

## 追記（実機フィールド報告への対応・セッション排他性のライトウェイト実装）

実機（本物のApple TV）で「UIハングは解消したが、①高速切り替え時に旧曲と新曲が二重に鳴る、
②アルバムを高速で無音のまま素通りする（曲が瞬時に次々`finished`扱いになる）、③再生開始30秒以内の
切り替えで①②が起きやすい」という報告を受けた。本ドキュメント「今後」節で設計メモを残していた
フル `actor StreamSession` 統合（`TVRelayStreamPlayer`+`TVSongStreamController`+
`TVRelayPlaybackController`を単一actorへ統合）は、既存200+テストの移行コストに対して、実際の
3症状の根本原因はそこまでの再構築なしに解消できると判断し、今回は「MainActorが唯一のエントリ
ポイントであり、セッションIDで全イベントをゲートする」という不変条件を、既存のクラス構成を保った
まま`session ID`相当の仕組み（インスタンス同一性 + `generation`カウンタ + `playToken`）で満たす
軽量な実装とした。

### 根本原因の特定（コード読解で確認、実機なしで再現できるユニットテストも作成）

| 症状 | 根本原因 |
| :--- | :--- |
| ① 二重音声 | `TVRelayStreamPlayer`は**インスタンスごとに専用の`AVAudioEngine`**を持つ（設計判断は型doc comment「Engine choice」参照）。`stop()`は`engineQueue.async`（fire-and-forget）で解体するため、新しいセッション（別インスタンス、別エンジン）が音を鳴らし始めても、旧エンジンがまだ`engineQueue`のバックログを処理中で物理的にレンダリングを続けている窓が存在した。ハードウェア出力レベルでは両エンジンが同時にAVAudioSessionへミックスされるため、実機でのみ「二重に鳴る」として顕在化する（テストは`muteOutput: true`で検証していたため、この窓の存在自体は今まで可視化されていなかった）。 |
| ② アルバム高速素通り（無音finished連鎖） | `TVPlaybackController.play(_:queue:)`は`async`で複数の`await`（キャッシュ判定・ラウドネス取得・ダウンロード）を挟むが、呼び出し側を直列化する仕組みが存在しなかった。`advanceAfterStreamEnd`/`advanceStreamingQueue`は`Task { await self?.play(...) }`という非追跡のfire-and-forget Taskで次の`play()`を発火するため、ユーザーの連続タップや自動アドバンスが積み重なると**複数の`play()`呼び出しが`await`のサスペンションポイントで交互に実行され得る**（`await`地点でMainActorが他のTaskに実行権を渡すため）。後発の呼び出しが先に副作用（`streamController.start`/`player.play`）に到達すると、先発の呼び出しが後からその副作用を追い越して発火し、直前に始まったセッションを即座に`teardown`→`onStreamEnded`させる、という連鎖が起き得た。これが「曲が一瞬も鳴らないまま次々`finished`扱いになる」という観測と一致する。 |
| ③ 起動30秒以内の切替不安定 | ①②の窓はどちらも「新旧セッションが半端に重なっている」時間帯でこそ踏みやすく、`didStartRendering`前（ジッターバッファが満ちる前）の"半初期化"状態はまさにその窓が長く開いている状態だった。①②を構造的に閉じることで③も同時に解消される（③単独の別バグではなく①②の発現条件という位置づけ）。 |

### 実装した修正（すべて既存クラス構成のまま、`progress`記載の不変条件をコードで強制）

1. **`TVRelayStreamPlayer.silenceImmediately()`**（`UX-Music-Mobile/Services/TVRelayStreamPlayer.swift`）
   `stop()`の先頭で**同期的に**（`engineQueue`を待たず、呼び出し元スレッド＝常にMainActorで）
   `playerNode.volume = 0` / `engine.mainMixerNode.outputVolume = 0`を設定する。両プロパティは
   Appleのドキュメント上、エンジン稼働中でも任意スレッドから安全に設定できるレンダーパラメータ
   （`connect`/`detach`のようなグラフ位相変更ではない）と明記されている。これにより「新セッションの
   最初の音が鳴る時点で旧セッションは可聴状態ではない」ことを**構築的に**保証する。実際のグラフ解体
   （`detach`/`engine.stop()`）は従来どおり`engineQueue.async`のままでよい（もう可聴ではないので
   タイミングは無関係）。テスト可視化のため`isRenderActiveForTesting`フラグを追加（`schedule()`が
   ジッターバッファを満たした時に`true`、`silenceImmediately()`で`false`）。
2. **`didCompleteWithError`の`generation`再チェック**（同ファイル）
   正常終了（`error == nil`、Task Aの有限ストリームにとっての「曲終わり」シグナル）パスに、
   `didReceive data:`と同じ「delegateキュー上で先にgenerationを捕獲→`DispatchQueue.main.async`内で
   再チェック」パターンを追加。`stop()`と`didCompleteWithError`のレース（`task.cancel()`が
   `NSURLErrorCancelled`ではなく正常終了として先に届く極小窓）に対する多重防御。
3. **`player === streamPlayer`同一性チェック**（`TVSongStreamController`/`TVRelayPlaybackController`
   の全`TVRelayStreamPlayerDelegate`実装）
   「EVERY upstream event carries its sessionID; the coordinator drops events whose ID ≠ current」
   をコードで明示。`teardown()`が同期的にdelegateをnilしているため実質的には従来から到達不能だった
   経路だが、暗黙の呼び出し順序ではなく型レベルで強制する。
4. **`TVPlaybackController.playToken`**（`play(_:queue:)`）
   呼び出しの先頭で`playToken`をインクリメントし`myToken`として捕獲、各`await`境界の直後に
   `myToken == playToken`を再チェックしてから次の副作用に進む。不一致なら即座にreturnし、
   一切の状態変更（`streamController.start`/`player.play`/キュー更新）を行わない。これにより
   `play()`の複数同時呼び出しが自己supersede化され、「最後にトークンを取った呼び出しだけが
   実際に音を出す」ことを構築的に保証する（MainActorの単一エントリポイント性を`playToken`という
   最小限の機構で「唯一のセッションだけが副作用を持つ」不変条件に変換）。フル`actor`化はせず、
   `@MainActor final class`のままトークンチェックだけを追加する形にとどめた——`play()`の外から
   見た振る舞い（superseded call is a silent no-op）は設計メモにあった「actorのみが排他制御を持つ」
   と等価だが、実装コストと既存テスト互換性の両立を優先した判断。

### 回帰テスト（`UX-Music-TVTests/TVPlaybackStressTests.swift`に追加）

1. `testOldSessionIsSilencedNoLaterThanNewSessionsFirstAudio` — セッションAをジッターバッファを
   超えて実際にレンダリング中の状態まで進め、その状態で`stop()`した瞬間に`isRenderActiveForTesting`
   が`false`になっていること、かつセッションBが初回レンダリングに達するまでの間ずっと`false`のまま
   であることを検証。二重音声症状に対する直接的な非可聴性の証明。
2. `testThirtyRapidHopsWithRandomGapsEndsOnLastRequestedSongWithNoSpuriousAdvance` — 決定論的
   （seed=42固定の線形合同法）な30回の`play()`呼び出しを、50〜500msのランダム間隔で**追跡しない
   `Task`から非同期発火**（`await`せず次のホップへ進む＝実際の高速連打/自動アドバンスの重なりを
   再現）。最終的に`player.currentSong`が最後にリクエストした曲と一致することのみを検証（到達す
   ること自体、および最終状態の正しさが回帰シグナル）。
3. 既存の`testStopWhileChunksArrivingThenImmediateRestartTwentyTimesDoesNotHang`
   （20回の`stop`/`start`連打）、`testFiftyRapidPlaySwitchCyclesAlternatingStreamAndCachedEndsOnLastRequestedSong`
   （50回連打）、`testPauseResumeIdentityAfterFiveConsecutiveSwitchesAffectsCurrentSongOnly`
   （5連続切替後のpause/resume同一性）は無変更のまま全green。

### テスト結果
- tvOSフルスイート（124件、新規2件を含む）を3回連続実行、すべて `** TEST SUCCEEDED **`。
- iOSフルスイート（共有コア`TVRelayStreamPlayer.swift`を変更したため実行、iPhone 17シミュレータ）
  も `** TEST SUCCEEDED **`。

### 見送った選択肢（フル`actor StreamSession`統合）
本ドキュメント「今後」節の設計そのものは依然として有効な将来オプションとして残す。今回の3症状は
「MainActor→session間の非同期fire-and-forgetな解体」と「並行`play()`呼び出しの非直列化」という
2点の局所的な穴が原因であり、`playToken`＋同期ミュートで閉じられることを実機報告の症状と1:1で
対応づけて確認できた。`generationLock`/`dispatchToMainSync`（監査の危険度3位・4位、UIハングとは
別カテゴリ）は今回もスコープ外のまま。
