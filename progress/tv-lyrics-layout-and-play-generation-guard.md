# TV: 歌詞レイアウト崩壊とMusicPlayerService世代ガード

## 決定

### 1. 歌詞表示時のNowPlayingレイアウト崩壊（ジャケットが画面に突き刺さる）
- 原因: `TVNowPlayingLyricsLayout` 内の `TVLyricsStageView` は素の `GeometryReader` を含むが、歌詞カラムのVStackに高さ制約が無く、無限の高さ提案がそのまま届いて画面全高まで貪欲に膨張。420pt固定のアートワークカードとの行の高さ交渉が破綻していた（歌詞なし曲は `TVLyricsStageView` 自体をマウントしないので無傷）。
- 修正: `TVNowPlayingLyricsLayout` の最外周に `GeometryReader` を置き、画面高からpadding(80×2)を引いた有限の `contentHeight` を算出して歌詞カラムのVStackに `maxHeight` として明示。`TVLyricsStageView` は `.frame(maxHeight: .infinity)` でその天井まで伸びる。高さの上限が「周囲のビュー木が偶然与える制約」ではなく「実キャンバスサイズ由来の明示的な数値」になったため、兄弟ビューの追加・削除で再発しない。

### 2. 曲切替後のシークバー暴走・停止不能
- 原因: TV/iOS共有のキャッシュ再生パス `MusicPlayerService` の `play()`→`loadAndPlay()` 連鎖に世代ガードが皆無だった。`loadAndPlay` は `preparePlaybackSessionIfNeeded()` と `Task.yield()` で必ずサスペンドするため、その間に次曲の `play()` が割り込むと2つの呼び出しがMainActor上でインターリーブし、`currentAudioFile`・再生位置・エンジングラフを相互に上書き。負けた側の末尾の `playerNode.play()` がポーズ/停止を打ち消す。`TVPlaybackController.playToken` は `player.play()` の境界で効力が切れる。
- 修正: `PlaybackGenerationGuard`（単調増加トークン、`Services/PlaybackGenerationGuard.swift`）を導入。全エントリポイント（`play`/`next`/`previous`/`playQueueItem`/`togglePlayPause`の再開分岐/`removeQueueItem`/リモートコマンド）で await 前に同期的にバンプし、`loadAndPlay` は各サスペンションポイント直後に `isCurrent` を再チェックして、追い越された呼び出しは無変更で離脱。`stop()` もバンプするため、飛行中の古い `loadAndPlay` が停止後に再生を復活させることもない。Go側 `relayEngine` の世代ガード修正（a4f2a09）と同じ規律。

## 却下した代替案
- 歌詞側: `TVLyricsStageView` 単体に固定高を与える案 → 呼び出し側のレイアウト意図（残り高さを歌詞が使う）を壊すため、上限は列側で画面由来の値として与える方式にした。
- 世代ガード側: `MusicPlayerService` を直接結合テストする案 → 既存ハーネスは実在しないファイルパスで `loadAndPlay` が早期returnする作りのため競合部を通らず、ガード有無でテスト結果が変わらない。ガードを小さな型に抽出して単体テスト（`PlaybackGenerationGuardTests`、6件）する方式にした。

## 制約・注意点
- `PlaybackGenerationGuard` はスレッドセーフではない。全呼び出し元が `@MainActor` 上で、インターリーブが `await` 境界のみで起きる前提。アクター跨ぎで共有しないこと。
- この環境ではCoreSimulatorのデバイスセットが初期化できず、`UX-Music-MobileTests` は未実行。TV/WatchスキームのSDKビルドは成功。実機環境で `xcodebuild test -only-testing:UX-Music-MobileTests/PlaybackGenerationGuardTests` を流すこと。
