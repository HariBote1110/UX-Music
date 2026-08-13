# tvOS 閲覧UI・擬似ストリーミング再生（Phase 1-3/1-4）

## Decision

- **棚構成**: アルバム（`Album.fromSongs` を iOS と共用）・プレイリスト（`/v1/remote/playlists`）の
  2 棚のみ実装。文字検索は主導線にせず、`.buttonStyle(.card)` による標準 tvOS フォーカス演出
  （カードリフト）を採用（`TVBrowseView.swift`）。
- **アートワーク**: `RemoteAPIClient.artworkURL(artworkId:)`（`?token=` 済み URL）を
  `AsyncImage` にそのまま渡す非同期ロード＋プレースホルダー（`TVArtworkImage`）。iOS 側の
  アートワークローダーはディスクキャッシュと密結合で共有に適さないため、TV 専用の薄い実装とした。
- **再生パイプライン**: 新規コードパスを増やさず、既存 `MusicPlayerService`（EQ + LUFS、
  iOS/watchOS と共有）をそのまま利用。`MusicPlayerService` は `Song.path`（ローカルファイルパス）
  を読むだけなので、TV 側の役割は「再生前にそのパスへ実ファイルを用意すること」だけに限定した
  （`TVPlaybackController`）。ラウドネス正規化も `MusicPlayerService.loudnessMap` に
  `/v1/remote/loudness` の値を渡すだけで既存のゲイン計算（`targetLUFS - songLUFS` →
  `pow(10, gainDb/20)`）がそのまま適用される。TV 側での再実装はしていない。
- **先読み**: `TVPrefetchPlanner.songIdsToPrefetch` は現在曲＋キュー先頭 2 曲（既定値）を
  純粋関数として返す。ネットワーク／ディスクを一切触らないため XCTest で直接検証できる。
- **キャッシュ（`TVPlaybackCacheStore` / `TVPlaybackCachePlan`）**:
  - 置き場所は `Caches/TVPlaybackCache/`（OS がパージし得る前提）。上限 2GB（既定値）。
  - 削除順序（LRU）の意思決定は `TVPlaybackCachePlan.entriesToEvict` に切り出した純粋関数。
    「最終アクセスが古い順に、保護対象（現在再生中・先読み対象）を除いて、必要バイト数を
    確保できるまで削除する」というルールを、ディスク I/O なしで XCTest 検証している。
  - 実ファイル I/O・LRU 実行・エビクションは `TVPlaybackCacheStore`（actor）が担当。
  - UI 上に「ダウンロード済み」概念は一切出していない（棚・再生画面ともにキャッシュ状態は
    表示しない）。
- **再生中パージ対策**: `TVPlaybackCacheStore.pinCurrentlyPlaying(songId:)` で現在再生中ファイルの
  `FileHandle` を開いたまま保持する。APFS/HFS+ では unlink 済みでも fd を閉じるまでデータが
  生き続けるため、エビクションが誤って現在再生中ファイルを削除しても再生自体は継続する
  （**保証ではなく緩和策**である点を明記: パスから再オープンが必要な操作——例えばコールドリランチ
  後の再開——はこの保護の対象外）。加えて `entriesToEvict` の `protectedSongIds` 引数で
  現在再生中・先読み対象の songId は最初からエビクション候補から除外している（二重の保護）。
- **エラー処理**: Host 不達時は `TVPlaybackController.connectionState = .unreachable(message:)`。
  オフラインモードは実装しない（計画どおり）。

## Alternatives considered

- **AVPlayer による直接ストリーミング**: 採用せず。EQ/LUFS を全端末で一貫させるという既存方針
  （`markdown/appletv-servermode-plan.md` の明文化事項 5）に反するため。
- **TV 専用のラウドネスゲイン再実装**: 不要と判断。`MusicPlayerService.applyLoudnessGain` は
  private だが `loudnessMap` 経由で同じロジックが自動適用されるため、re-export や複製をしない
  方が保守コストが低い。
- **iOS のアートワークキャッシュを共有ターゲット化**: 見送り。iOS 側はオンデバイス永続キャッシュ
  前提の設計で、tvOS の「OS がいつでもパージしてよい」方針と噛み合わないため、TV ローカルの
  薄い実装に留めた。

## Constraints / Gotchas

- **最近再生棚は未実装**: `/v1/remote/*` に再生履歴を返すエンドポイントが存在しない
  （`fetchSongs`・`fetchDesktopPlaylists`・`fetchLoudness`・`fetchLyrics`・`fetchState` のみ）。
  計画書どおり「データ源がなければ棚ごと出さない」を採用。将来 `/v1/remote/history` 等が
  追加された場合、`TVBrowseModel` に棚を足す形で拡張できる。
- **お気に入り棚も未実装**: Mobile 側にお気に入り機能自体が実装されていないため、計画書の
  「Mobile 側実装状況に追従」ルールに従い省略。
- **`TVPlaybackCacheStore.estimatedIncomingBytes`**: ダウンロード開始前は実ファイルサイズが
  不明なため、64MB の固定見積りでエビクション要否を判定している。ダウンロード完了後の実サイズは
  `currentEntries()` がディスクから都度読み直すため、次回のエビクション判定には反映される
  （見積り誤差は次サイクルで自己修正される設計）。
- **`pinCurrentlyPlaying` は `FileHandle` を開くだけ**で `AVAudioFile` 自体の生存は保証しない。
  `MusicPlayerService` は `AVAudioFile(forReading:)` を都度開くため、再生開始後にファイルが
  物理的に消えると次の `seek`/再スケジュール時に失敗し得る。Phase 1 では発生頻度が低いと判断し
  実装を簡素化したが、実機検証で問題が出た場合は `TVPlaybackCacheStore` 側でエビクション対象から
  「再生中」を最優先で除外する仕組みを強化する。

## 追記（2026-08-13）: 実機報告「再生開始が遅すぎる」の調査と修正

### 真因

`TVPlaybackController.play(_:queue:)` が **現在曲＋先読み対象（既定で次の2曲、計3曲）の
フルファイルダウンロードを全部 `await` し終えてから** `player.play(...)` を呼んでいた
（`for id in idsToPrefetch { ... try await cache.ensureCached(...) ... }`）。先読みは本来
「次の曲のための事前準備」であり、現在再生中の音声には無関係のはずなのに、実装上は
タップ→初回音声のクリティカルパスに丸ごと乗っていた。加えて `client.fetchLoudness()`
（LAN API 呼び出し）も現在曲のダウンロードより前に直列で `await` していた。ライブラリの
約88%が FLAC（実測: 1曲あたり 30〜60MB）であるため、この直列化は「現在曲1曲分」の
3倍近い待ち時間をユーザーに強いていた。

ダウンロード経路自体（`RemoteAPIClient.downloadFile` は既定で `source=original` を付け、
デスクトップ側の生ファイルをそのまま返す）はボトルネックではないことを実測で確認済み
（同一Mac上のループバックで 45.9MB の実FLACが 54ms、931曲のライブラリを持つ実ホストに対して）。
一方 `source=original` を付けずに叩くと（トランスコード経路）5.5MBのAAC変換に2.6秒かかる
ことも判明したが、これは既存コードが最初から `preferOriginalAudio: true` を既定にしていたため
実害はなかった（誤って `source=original` を外す変更を将来しないよう、ここに実測値を残す）。

### 修正

`TVPlaybackController.play`:
- **現在曲のダウンロードのみ** を `await`（`cache.ensureCached(songId: song.id, ...)`）。
- ラウドネス取得は `async let loudnessTask = client.fetchLoudness()` で現在曲ダウンロードと
  並行実行し、`player.play` 直前に `await`（同じレイテンシ予算内に収まるので、現在曲より
  ダウンロードが速いラウドネスAPIがクリティカルパスを伸ばすことはない）。
- **先読み対象の残り（現在曲を除いた分）は `Task.detached(priority: .utility)` で
  fire-and-forget** にし、`player.play` 呼び出し・`connectionState = .ready` の後に発火する
  ようにした。エラーは無視（`try?`）——先読み失敗は「次の曲の再生開始が遅くなる」という
  縮退にしかならず、現在の再生を止める理由にはならない。
- `DEBUG` ビルドで `[TVPlay] tap→firstAudio: <ms>` を計測ログ出力するようにした
  （`DispatchTime` ベース、`play()` 呼び出し開始から `player.play` 完了までを計測）。

### 検証（実測値）

Apple TV シミュレータ（`UXTV_PREVIEW=livenowplaying` — 新設の DEBUG 専用ハーネス、
`UXMusicTVApp.swift` の `TVLiveNowPlayingHarness`）から、稼働中のライブホスト
（`http://127.0.0.1:8765`、実ライブラリ931曲、`masterVolume = 0` でミュート）に対し、
現在曲＋次2曲（既定の `prefetchCount`）を含む実キューで `TVPlaybackController.play` を実行し、
`[TVPlay]` ログをキャッシュクリア済みの状態から測定（同一Mac上のループバック接続、
3曲とも実FLAC・約束キャッシュなしの初回ダウンロード）:

- **修正前**（3曲を直列 `await` するアルゴリズムに `[TVPlay]` ログのみ追加した一時ビルドで測定）:
  **471ms**
- **修正後**（本修正）: **309ms**（約 34% 短縮）

ループバック接続のため絶対値は実際のWi-Fi環境より大幅に小さいが、短縮の構造は
「現在曲1曲分の待ちから、先読み分（2曲分）の待ちを完全に除去した」ことによるもので、
実際のWi-Fi環境（1曲あたりのダウンロードが数百ms〜数秒かかる想定）では短縮の絶対時間が
このループバック計測より大きく開くと見込まれる（先読み2曲分のダウンロード時間がまるごと
クリティカルパスから外れるため）。

### 次の一手（今回は実装しない）

大容量FLACのフルファイルダウンロード自体がWi-Fi実測でボトルネックになる場合、次のレバーは
チェイス再生（部分ファイル受信しながら再生開始する擬似ストリーミング）——計画書
（`markdown/appletv-servermode-plan.md`）で既に触れられている方向性。今回はタップ→初回音声の
「順序・並行性」の修正に留め、チェイス再生の実装には着手していない。

## 追記（2026-08-13）: ストリームファースト再生（Task A、キャッシュミス時の"待たせない"再生）

### 設計

「次の一手」で触れたチェイス再生の実装。キャッシュヒット時は上記の修正済みパスをそのまま
使う。**キャッシュミス時**は、デスクトップ側で並行整備中の
`GET /v1/remote/file?id=…&stream=aac`（チャンクADTS AAC-LC 256kbps/44.1kHz/stereo ——
`GET /v1/remote/relay` と完全に同一フォーマット）を使い、フルファイルダウンロードを待たずに
即座に再生を開始する:

1. `TVPlaybackController.play` は `cache.isCached(songId:)`（ディスクI/Oのみ、ネットワーク
   往復ゼロ）でキャッシュヒット/ミスを判定。
2. ミスなら `TVSongStreamController.start(songId:outputGain:)` を即座に呼ぶ。内部では
   **リレー受信で実装済みの `TVRelayStreamPlayer`（`URLSession`ストリーミング → 
   `ADTSFrameParser` → `TVAACDecoder` → ジッタバッファ → 専用`AVAudioEngine`）をそのまま
   再利用**——フォーマットがリレーと同一なので新規デコードパイプラインは不要と判断。
   `TVRelayStreamPlayerDelegate` に `relayStreamPlayerDidReachEndOfStream` を追加し
   （`didCompleteWithError: nil` を「曲の終端」として通知）、有限長の曲ストリームでも
   「いつ次の曲へ進むか」を検出できるようにした（リレーの継続ストリームでは実質発生しない
   イベントだが、プロトコルとしては両者で共有）。
3. 同時に `TVPlaybackCacheStore.ensureCached` を `Task.detached` でバックグラウンド起動し、
   オリジナルファイルをキャッシュへDL。**曲の途中でストリーミング→キャッシュ再生への
   ホットスワップはしない**（ユーザーに違和感のあるバッファ切り替え/音飛びのリスクがあり、
   今回のスコープでは正当化できないと判断——次回再生 or リピート時に自然にキャッシュ経路へ
   切り替わる設計で十分）。将来ホットスワップしたくなった場合の拡張ポイントとしてのみ
   ここに記録する。
4. トラック終端（ストリームの正常終了）はストリーム側で検出し、
   `TVPlaybackController.advanceAfterStreamEnd` がキュー内の次の曲へ`play(_:queue:)`を
   呼び直す。`MusicPlayerService.advanceAfterEnd()`（リピートモード対応・キュー管理）は
   ローカル再生専用でストリーミング経路には関与しないため、ストリーミング側は意図的に
   「次の1曲へ進むだけ」の最小実装とした（リピートモード等はその次の`play()`呼び出しが
   キャッシュ/ストリームどちらを選ぶかを含めて自然に再評価される）。

### EQ/LUFSのルーティング判断

`MusicPlayerService`の10バンド`AVAudioUnitEQ`は完全にprivateで自分のエンジンに紐づいており、
別エンジン（`TVRelayStreamPlayer`の専用`AVAudioEngine`）から再利用する経路がない
（コードを読んで確認済み）。フルEQグラフを別途複製するコストは、キャッシュ完了後の次回再生では
どのみち通常のEQ付き再生に切り替わる「数十秒〜数分のワンショットの窓」のためだけに見合わない
と判断した。一方でラウドネス（LUFS）正規化は音量差が体感として大きいため省略しないことにし、
`MusicPlayerService.applyLoudnessGain()`と同じ線形ゲイン式（`10^((target-lufs)/20)`、
`0...4`にクランプ）を`TVPlaybackController.linearLoudnessGain`として複製し、
`TVRelayStreamPlayer.outputGain`（`mainMixerNode.outputVolume`に反映）へ渡す方式にした。
リレー経路（ホスト自身のミックス済み音声）は従来通りgain=1のまま変更していない。

### 検証

- `TVSongStreamPlaybackReducer`/`TVSongPlaybackPlan`（loading→streaming→finished/failed の
  純粋状態機械、キャッシュヒット判定）を単体テストでカバー
  （`UX-Music-TVTests/TVSongStreamPlaybackReducerTests.swift`）。
- `RemoteAPIClient.songStreamRequest`/`songStreamQueryItems`（`stream=aac`クエリ+
  Authorizationヘッダの構築）を単体テストでカバー（`RemoteAPIClientTests.swift`）。
- `TVPlaybackController.linearLoudnessGain`は当初`@MainActor`分離の`TVPlaybackController`の
  static funcとして実装したため、非MainActorのテストコンテキストから直接呼べず
  ビルドが失敗した。ゲイン計算自体はアクター状態に依存しない純粋関数なので
  `nonisolated static func`に変更し解消（`TVPlaybackControllerGainTests.swift`で
  `MusicPlayerService.applyLoudnessGain()`と同じ式であることを回帰カバー）。
- **モックストリームサーバでのE2Eレイテンシ計測は2案とも失敗し、断念した**:
  1. `Network.framework`の`NWListener`でループバックHTTPサーバを立てる案 →
     シミュレータのテストランナー上で永久にハングした（macOSのローカルネットワーク権限
     ダイアログをヘッドレスでは誰も許可できず、ブロックされ続けていると見られる）。
  2. `URLProtocol`スタブ（`URLSessionConfiguration.protocolClasses`経由でリクエストを
     プロセス内でインターセプトし、実ソケットを一切使わない）に切り替えた案 →
     ソケットは回避できたが、`TVRelayStreamPlayer`の内部`URLSession`に対して
     スタブが一度もインターセプトされず（`didStartRendering`/`didFailWith`のどちらの
     delegateコールバックも発火せず10秒でタイムアウト）、原因を追う時間的余裕がなく
     断念した。
  テストコード自体は削除し（赤いテストを残さない方針）、`xcodebuild test`によるtvOS
  ターゲット全体のユニット/統合テストスイートは green を確認済み。
- **未実施**: 実デスクトップの`stream=aac`エンドポイントに対する実測レイテンシ
  （このセッション実行時点でエンドポイントが並行実装中のため測定不能）。モックサーバでの
  自動化レイテンシ計測も上記の理由で断念したため、次回はデスクトップ側エンドポイントが
  着地した実機/実ホスト構成で`[TVPlay]`ログと同様の計測ログを追加して実測することを
  推奨する。
- シミュレータでの選択→ローディングUI→初回音声のE2Eスクリーンショットは、
  `UXTV_PREVIEW`系のDEBUGハーネスが「ペア済みホストへの接続」を前提とする構成が多く、
  ホストへの書き込み系操作が本タスクの制約で禁止されていたため、ストリーミング選択の
  トリガー自体を再現できず未実施。`TVStreamLoadingOverlay`のコード自体は
  `xcodebuild build`で型チェック済み。

### 却下した代替案

- **曲の途中でのストリーム→キャッシュ済みファイルへのホットスワップ**: ブリーフで明示的に
  却下・将来オプションとして指定されていたため実装せず。
- **ストリーミング経路にもフル10バンドEQを複製**: 上記「EQ/LUFSのルーティング判断」参照。

## 追記（実機クラッシュ修正・Now Playing統合・URLProtocolモックE2Eの決着）

### クラッシュの根本原因

実機での再現手順（未キャッシュ曲をストリーミング再生→バックアウト→同じ曲を再再生）で報告された
`AVAEInternal.h:71 required condition is false: [_nodes containsObject: node1] &&
[_nodes containsObject: node2]`（`AVAudioEngine.connect`内）は、`TVRelayStreamPlayer`の
`engine`/`playerNode`に対する**スレッド間の無同期な競合**が原因だった。

- `URLSessionDataDelegate`のコールバック（`didReceive data:`→`handle`→`schedule`）は
  `URLSession`のデリゲートキュー（バックグラウンドの`OperationQueue`）上で実行される。
- 一方`stop()`は常に`TVSongStreamController`（`@MainActor`）から呼ばれる＝メインスレッド。
- 両者は`engine.attach`/`engine.detach`/`engine.connect`という同じミュータブル状態を
  一切の同期なしに触っていた。ユーザーがバックアウトした瞬間にはすでにデリゲートキューへ
  ディスパッチ済みのチャンクが残っており、その`schedule()`が`engine.connect(playerNode, …)`を
  実行するのと、`stop()`側の`engine.detach(playerNode)`がメインスレッドで実行されるのが
  競合レースになり得た。「detachされた直後のノードへconnectする」「まだattachされていない
  ノードへconnectする」のどちらの順序でも`_nodes`に対象ノードが含まれない状態で`connect`が
  呼ばれ、クラッシュに直結する。

`TVSongStreamController`/`TVRelayPlaybackController`はどちらも`start()`のたびに
**新しい`TVRelayStreamPlayer`インスタンス**を生成しており（インスタンス使い回しではない）、
複数インスタンス間の競合ではなく、**単一インスタンスの`stop()`とその直前に受信済みだった
チャンクの遅延処理との自己競合**である点に注意。

### 修正内容

`TVRelayStreamPlayer`に専用のシリアルディスパッチキュー`engineQueue`を新設し、
`engine`/`playerNode`/`isEngineConnected`/`parser`/`decoder`への全アクセスを
このキュー上に一本化した。

- `start()`・`stop()`は`engineQueue.sync`で実行 — `stop()`が返った時点で、進行中/キュー済みの
  `schedule()`は必ず完了している（`stop()`と`handle`/`schedule`が絶対に交錯しない）。
- `stop()`のたびに`generation`カウンタをインクリメントし、`urlSession(_:didReceive:)`は
  受信時点の`generation`を`engineQueue.async`クロージャに閉じ込める。`handle`/`schedule`は
  毎フレームその値を現在の`generation`と比較し、不一致（＝すでに`stop()`された古いセッション）
  なら即座に何もせず抜ける。デリゲートキュー上で受信済みだが未処理だったチャンクが、
  すでに解体されたエンジンに触れることはなくなった。
- `schedule()`にも`engine.attachedNodes.contains(playerNode)`の防御チェックを追加し、
  万一`generation`チェックをすり抜けても`connect`が未attachのノードに対して呼ばれることはない。

### 回帰テスト

`UX-Music-TVTests/TVRelayStreamPlayerLifecycleTests.swift`を新設。
`URLProtocol`スタブ（`ChunkedFixtureURLProtocol`）で`relay-sample.aac`フィクスチャを
4096バイトずつ・2ms間隔でチャンク配信し、**同一の`TVRelayStreamPlayer`インスタンスに対して
start→（`didStartRendering`まで待機）→stop→即start→stopを2回連続実行**して、両方とも
クラッシュせず`didStartRendering`が発火することを確認する。実機の再現手順（バックアウト＝
ストリーム途中でのstop、直後の同曲再再生）を`stop()`のタイミングごと再現している。

**前回セッションの`progress`追記にあった「`TVRelayStreamPlayer`の内部`URLSession`に対して
`URLProtocol`スタブが一度もインターセプトされなかった」問題はここで解決した**: 原因は
スタブ登録自体ではなく、`TVRelayStreamPlayer.init`に渡す`URLSessionConfiguration`を
呼び出し側が実際に注入できていなかった構成だったと見られる。今回は
`TVRelayStreamPlayer(sessionConfiguration:muteOutput:)`に明示的に
`protocolClasses = [ChunkedFixtureURLProtocol.self]`を設定した`.ephemeral`構成を渡し、
`didStartRendering`/RMSログとも正常に発火することを確認した。

### Now Playing統合（ストリーミング中に何も表示されない問題）

`TVNowPlayingView`は`MusicPlayerService.currentSong`/`isPlaying`/`positionSeconds`
**のみ**を観測しているが、ストリーミング経路（`TVSongStreamController`→
`TVRelayStreamPlayer`）は`MusicPlayerService`を一切経由しないため、音声は鳴っていても
Now Playing画面のタイトル/アートワーク/進捗が空のままになっていた。

**採用した方式（ブリーフの選択肢(b)）**: 別エンジンは維持したまま、`MusicPlayerService`へ
メタデータ/進捗をミラーリングし、トランスポート操作をストリーム側へルーティングするブリッジを
追加した。

- 却下した(a)（デコード済みPCMを`MusicPlayerService`のエンジンへ直接スケジュールする案）:
  `MusicPlayerService`のスケジューリングAPIは`AVAudioFile`前提（`playerNode.scheduleSegment`/
  `scheduleFile`）で、ファイルなしのバッファ列を流し込む経路が存在しない。追加するには
  `MusicPlayerService`の再生コア（EQ/LUFS/シーク/自然終了検出を含む）に新しい入力経路を
  割り込ませる必要があり、共有サービス（iOS/watchOSとも共通）への影響範囲が大きすぎると判断。
- (b)は`TVRelayStreamPlayer`の「専用エンジンを維持する」既存設計判断（EQ/LUFSのルーティング
  判断と同じ理由）と一貫しており、変更が`MusicPlayerService`の薄いブリッジAPI追加と
  `TVPlaybackController`の配線だけで完結する。

**`MusicPlayerService`側の追加API**（"External playback bridging"セクション）:
`isExternallyDriven`フラグ、`beginExternalPlayback(song:durationSeconds:)`、
`updateExternalPlaybackProgress(seconds:)`、`setExternalPlaybackIsPlaying(_:)`、
`endExternalPlayback()`、`externalPlaybackCommandHandler`。
`togglePlayPause()`/`next()`/`previous()`/`stop()`は`isExternallyDriven`のとき
真っ先に`externalPlaybackCommandHandler`へルーティングし、ローカル`AVAudioEngine`/YouTube
バックエンド（ストリーミング曲にはファイルが存在しない）には一切触れない。
`play(_:newQueue:)`（キャッシュ済みパスへの引き継ぎ時）は`isExternallyDriven`を強制解除する。

**`TVRelayStreamPlayer`側の追加**: `elapsedSeconds`（`playerNode.playerTime(forNodeTime:)`
から算出、`MusicPlayerService.currentTimelineSeconds()`と同じ手法）、`pause()`/`resume()`
（`engineQueue`経由）。

**`TVPlaybackController`の配線**: ストリーム開始直後（`didStartRendering`を待たず）に
`player.beginExternalPlayback`を呼び、250ms間隔の`Task`ループで`elapsedSeconds`を
`updateExternalPlaybackProgress`へミラーリング。`externalPlaybackCommandHandler`で
`.togglePlayPause`→`streamController.togglePlayPause()`、`.next`/`.previous`→
キュー内インデックスを±1して`play()`を再呼び出し、`.stop`→`streamController.stop()`に
それぞれルーティング。

### シミュレータE2E（決着）

前回断念していた「`UXTV_PREVIEW`ハーネスはペア済みホスト接続前提でストリーミング選択自体を
再現できない」問題を、`TVSongStreamController`に`streamPlayerFactory`の注入点を追加すること
（テストと同じ理由・同じ解決策）で解消した。`UXTV_PREVIEW=songstream`
（`UXMusicTVApp.swift`の`TVSongStreamPreviewHarness`）は、ライブホストなしで
`TVPlaybackController.play`のキャッシュミス経路をフルに駆動する：

- `RemoteAPIClient`は到達不能なループバックポート（`fetchLoudness`/バックグラウンドDL失敗は
  `try?`で握り潰され無害）、`TVPlaybackCacheStore`は毎回使い捨ての一時ディレクトリで
  常にキャッシュミス、`TVRelayStreamPlayer`のセッションだけ`UXTVSongStreamMockURLProtocol`
  （`relay-sample.aac`をチャンク配信）を注入。
- `UXTV_SONGSTREAM_REPLAY=1`で「初回ストリーム開始→2秒待機→同曲を`play()`で再度呼び出し
  （`stop()`→`start()`の実クラッシュ順序を再現）」まで自動実行し、
  `[SongStreamHarness] replay ok`ログとその後もプロセスが生存していることでクラッシュ非再現を
  確認できる。
- シミュレータ実行で確認: 初回ストリーミング中からNow Playingにタイトル「ストリーム検証曲」/
  アーティスト「UX Music Demo」/トランスポート（一時停止アイコン＝再生中）が表示され
  （従来は空白だった）、同曲の即時再再生後もクラッシュなくプロセスが生存し、Now Playingの
  表示も維持されることを確認（スクリーンショット2枚）。

### 未解決・今後の課題

- ストリーミング中の`durationSeconds`は呼び出し元が渡す`Song.duration`頼みで、実際の総再生時間
  をストリーム自体からは取得できない（ADTSには長さ情報がない）。実運用では`Song.duration`が
  Songテーブルの既知値のため実害は小さいが、明示しておく。
- アートワークは`TVNowPlayingView`が`client`経由で`artworkId`から画像を都度フェッチする
  既存の仕組みをそのまま利用しており、この変更では触れていない（ハーネスのスクリーンショットで
  プレースホルダーになっているのはモックホストへ到達できないためで、想定通りの挙動）。
