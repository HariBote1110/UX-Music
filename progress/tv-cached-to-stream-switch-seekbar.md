# TV: キャッシュ済み曲→非キャッシュ曲切替でのシークバー暴走・停止不能

## 症状（実機報告）

Apple TV実機で、キャッシュ済みの曲（`MusicPlayerService` 自前の `AVAudioEngine` によるローカル再生）を再生した直後に、未キャッシュの曲（`TVSongStreamController` によるストリーム再生）を再生すると:

- シークバーが新旧2曲の再生位置を行き来して暴走する。
- 再生を止められない（旧曲が鳴り続ける）。

## 真因

`MusicPlayerService.beginExternalPlayback(song:durationSeconds:)`（`TVPlaybackController.play()` がキャッシュミス時に呼ぶ、外部ストリーム再生開始のエントリポイント）が `isExternallyDriven = true` を立てるだけで、以下を一切していなかった:

1. **ローカル再生エンジンの停止** — 直前まで再生していた曲の `playerNode`/`engine` が止まらず、`currentAudioFile` も保持されたまま。旧曲の音声がそのまま鳴り続ける。
2. **`playGeneration` のバンプ** — `play`/`next`/`previous`/`playQueueItem`/`togglePlayPause` の再開分岐/`stop()` など、`loadAndPlay` に至る全エントリポイントは `progress/tv-lyrics-layout-and-play-generation-guard.md` の世代ガード規律に従って `await` 前に同期バンプする決まりだったが、`beginExternalPlayback` は「ローカルエンジンに一切触れない」外部ミラーリング専用の入口として書かれていたため、この規律から漏れていた。

結果として、`positionSeconds` の書き手が2つ同時に存在する状態になっていた:

- 250msごとの `positionTimer` → `tickPlaybackPosition()`（旧曲の**まだ生きている**ローカルタイムラインから位置を計算）
- `TVPlaybackController.progressMirrorTask`（250msごとに `updateExternalPlaybackProgress(seconds:)` でストリームの実経過秒を書き込む）

両者が交互に `positionSeconds` を上書きし合うため、シークバーが新旧の位置を往復する。さらに `isExternallyDriven` が真の間は `togglePlayPause()`/`stop()` が `externalPlaybackCommandHandler`（ストリーム側）にしかルーティングされない設計のため、まだ鳴っている旧曲のローカルエンジンへ止める手段が存在しなかった。

## 修正

不変条件「外部駆動中（`isExternallyDriven == true`）はローカルエンジンが必ず沈黙している」を、その状態を作る唯一のエントリポイントである `beginExternalPlayback` 自身で強制する:

1. `isExternallyDriven = true` を立てる**前**に `playGeneration.bump()` を呼び、飛行中の `loadAndPlay` を無効化する（他のエントリポイントと同じ規律）。
2. 続けて既存の `stopLocalPlaybackEngineOnly()`（`playerNode`/`engine` 停止・`currentAudioFile` クリア）を呼ぶ。iOS/watchOS では加えて `stopYouTubeBackend()` も呼ぶ（`stop()` が行っているのと同じ組み合わせだが、`queue`/`currentSong` はクリアしない）。
3. `tickPlaybackPosition()` の先頭に `isExternallyDriven` ガードを追加。外部駆動中はローカルタイムラインからの再計算・`positionSeconds` の上書きを一切行わず、Now Playing（ロック画面等）のメタデータ更新（`updateNowPlayingCentre()`）だけは継続する。これで `positionSeconds` の書き手が `updateExternalPlaybackProgress` 一本に統一される。

テスト用に `MusicPlayerService.hasActiveLocalAudioFileForTesting`（`currentAudioFile != nil` を公開するだけの読み取り専用シーム）を追加した。位置づけは `TVRelayStreamPlayer.isRenderActiveForTesting` と同じ。

### テスト

- `MusicPlayerServicePlaybackSpikeTests` 系の直接呼び出しレベル: キャッシュ曲を再生 → `beginExternalPlayback` を直接呼び、ローカルエンジンが即座に沈黙し `positionSeconds` の書き手が外部ミラーのみになることを確認。
- `TVPlaybackController` レベル（実際の再現経路）: `TVPlaybackCacheStore` を事前にキャッシュヒットさせた曲Aをローカル再生 → キャッシュミスの曲Bへ切替 → ローカルエンジンが停止し、ストリーミング中のシークバーが後退/往復しないことを確認。
  - `TVPlaybackController.play()` はキャッシュヒット判定を `cache.isCached()`（ディスク存在チェック）のみで行い、渡した `downloader` クロージャの成否では判定しない。そのためテストでキャッシュヒットを再現するには、`downloader` を通す（`cache.ensureCached` を先出しで呼ぶ）などしてディスク上に事前配置しておく必要がある。

いずれも `UX-Music-TVTests/TVPlaybackControllerCachedToStreamSwitchTests.swift` に実装。

## 却下した代替案

- `TVPlaybackController.progressMirrorTask` 側でローカルタイマーを止める／黙らせる案 → 修正対象が呼び出し側になり、`MusicPlayerService` 単体では相変わらず「外部駆動中でもローカルエンジンが生きたまま」という不変条件違反が残る。次に似た呼び出し元が増えたときに同じ不具合が再発するため却下し、`MusicPlayerService` 自身がエントリポイントで強制する方式にした。
- `isExternallyDriven` の setter に didSet でエンジン停止処理を差し込む案 → `beginExternalPlayback`/`endExternalPlayback`/`play()` 内の代入など複数箇所から `isExternallyDriven` が触られており、`playGeneration.bump()` のタイミング（await 前に同期的に、が規律）を didSet 経由で制御しづらいため、明示的にエントリポイント内で呼ぶ方式にした。

## 制約 / 注意点

- `playGeneration`（`PlaybackGenerationGuard`）はスレッドセーフではなく `@MainActor` 前提（`tv-lyrics-layout-and-play-generation-guard.md` に既出の制約）。`beginExternalPlayback` も同じ前提の呼び出し元（`TVPlaybackController`、MainActor）からのみ呼ばれる。
- `tickPlaybackPosition()` のガードは `isExternallyDriven` のみを見ている。将来 `isExternallyDriven` を経由しない第3の再生バックエンドが増えた場合は、同じく「positionSeconds の書き手は誰か」を明示的に確認すること。
