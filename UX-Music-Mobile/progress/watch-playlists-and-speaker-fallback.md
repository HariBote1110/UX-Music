# Watch: スピーカーフォールバック / Queue画面整理 / プレイリスト / アニメーション整合

## Decision

### 1. スピーカー再生フォールバック
`WatchAudioPlayerService.activateAudioSession` を二段構えにした。

1. まず `.playback` / `.longFormAudio` で `AVAudioSession` を有効化(Bluetooth出力が必要)。
2. 失敗したら `.playback` / `.default`(ポリシー省略)で再試行。watchOSは long-form
   ポリシーでのみ内蔵スピーカー再生を禁止しており、素の `.playback` カテゴリなら
   内蔵スピーカーでも鳴らせるため。

判定ロジックは `WatchAudioRoutePolicy`(`UX-Music-Watch/WatchAudioRoutePolicy.swift`)に
`Outcome { longForm / speakerFallback / unavailable }` として純粋関数で切り出し、
`WatchAudioRoutePolicyTests` でユニットテスト。両方失敗したときだけ `routeError`
(ブロッキング表示)を立て、スピーカーフォールバック時は新設の
`isSpeakerFallback` フラグを立てて Now Playing 画面に非ブロッキングの
"Playing on speaker" キャプションを出す。

### 2. Queue画面からボリューム削除・改名
Digital CrownがすでにNow Playing画面でボリュームを操作できるため、Queue画面の
常時表示ボリュームスライダー(`Section("Volume") { SystemVolumeControl() }`)は
冗長と判断し削除。`WatchQueueVolumeView` → `WatchQueueView` に改名
(`git mv` + 型名変更 + 全参照更新)。`SystemVolumeControl` 自体は
`WatchNowPlayingView` が非表示Crownフォーカス用に引き続き使うため型は残置
(定義は `WatchQueueView.swift` のまま — target-internal な既存の配置を踏襲)。

### 3. プレイリスト機能とデータ経路
既存のiOS/デスクトップ側 `Playlist`(`id`/`name`/`songIds`)と対応する
Watch専用の軽量モデル `WatchPlaylistMeta`(`WatchPlaylistModel.swift`)を新設。
`WatchTransferMeta` と同じ「Watch向けに最小限のフィールドだけを持つ別モデル」
という既存パターンを踏襲。

playlist→queue変換は `WatchPlaylistQueueBuilder`(純粋関数、
`resolvedSongs(for:librarySongs:)` / `queue(for:startingAt:librarySongs:)`)として
切り出し `WatchPlaylistQueueBuilderTests` でテスト。UI側
(`WatchPlaylistListView` → 詳細 → `WatchSongRow` タップ)は既存の
`WatchSongRow` の `player.play(meta, queue:)` をそのまま使うだけで
「タップした曲からプレイリストをキュー再生」を満たす。

**受信経路(Watch側は実装済み・iPhone送信側は未実装)**:
アートワークの `transferFile`(`kind: "artwork"`)と同じパターンで、
`kind: "playlists"` のタグを付けた `transferFile` を新設。ペイロードは
`[WatchPlaylistMeta]` をJSONエンコードしたファイル1本。
`WatchConnectivityReceiver.session(_:didReceive:)` で判定・デコードし
`WatchPlaylistLibrary.replaceAll(_:)`(`playlists.json` に永続化、
`WatchLocalLibrary` の `library.json` と同じ形)へ渡す実装まで完了。

**iOS側(`UX-Music-Mobile/UX-Music-Mobile/**` — Watch担当の所有範囲外につき未実装)
に必要な追加実装**:
`WatchTransferBridge`(`UX-Music-Mobile/Services/WatchTransferBridge.swift`)に
新規メソッドを追加し、
1. `PlaylistStore` から現在のプレイリスト一覧を取得
2. 各 `Playlist` を `WatchPlaylistMeta(id: $0.id, name: $0.name, songIds: $0.songIds)`
   にマップ
3. `[WatchPlaylistMeta]` をJSON encode して一時ファイルに書き出す
4. `WCSession.default.transferFile(tempURL, metadata: ["id": "playlists",
   "kind": "playlists"])` を呼ぶ

を実装する必要がある。呼び出しタイミングは既存の曲/アートワーク転送と同様、
ペアリング後・プレイリスト変更時などが妥当。

### 4. デスクトップ/iOS版とのアニメーション整合
シャッフル/リピートアイコンのスライドアニメーション(`ModeIconAnimationMaths`
/ `WatchModeIconViews.swift`)は移植済みだったが、それ以外のモーションが
全く無く「別アプリのように感じる」というユーザー指摘があった。

`WatchNowPlayingView` / `WatchSongListView` に追加した演出:
- 再生/一時停止ボタン: `.contentTransition(.symbolEffect(.replace))` でアイコンを
  モーフ(iOS版は実は単純な画像差し替えで演出は無いが、Watchらしい素材として
  symbolEffectを採用)。
- トラック切替時のアートワーク: `.id(cachedArtworkSongId)` +
  `.transition(.opacity)` + `.animation` でクロスフェード。
- タイトル/アーティスト表記: `.contentTransition(.opacity)` でフェード。
- プログレスバー: `.animation(.linear(duration: 0.5), value: progress.position)`
  で0.5秒Tick間の動きを滑らかに補間。
- 楽曲行(`WatchSongRow`)・トランスポートボタン: 押下時に `scaleEffect` で
  縮小するプレスフィードバック(`WatchPressableRowStyle` /
  `WatchTransportButtonStyle`)。iOS版の `SongRowView` 自体には明示的な
  アニメーションが無いが、watchOSの `.plain` ボタンスタイルは何のフィード
  バックも出さないため、タップの手応えとして追加。
- 音声出力の状態表示行(routeError / speakerフォールバックキャプション)の
  出し入れをフェードでアニメーション化。

**iOS版にあってWatchに移植できなかったもの**: `NowPlayingView` の
`nowPlayingPanelSpring` によるパネル開閉スプリング、YouTube埋め込みの
フェード、アートワークの `.spring(response:dampingFraction:)` はいずれも
iPad対応の複雑なパネルレイアウト/YouTube機能に紐づくもので、Watch側には
対応するUI要素自体が存在しない(Watchはページ送りが `TabView(.page)` の
ネイティブページングのみ)。

## Alternatives considered

- プレイリスト転送を専用の `WCSession.sendMessage` にする案 → 却下。
  アプリがバックグラウンド/未起動のときに届かない可能性があり、既存の
  `transferFile`(アートワークと同じ仕組み)の方が信頼性が高い。
- `WatchPlaylistMeta` を `Playlist` 型そのものにする案 → 却下。
  `Playlist` は iOS側所有ファイル(`Models/Playlist.swift`)にあり、
  Watch担当の編集範囲外。Watch専用の軽量モデルを新設する方が
  `WatchTransferMeta` の既存パターンとも整合する。

## Constraints / Gotchas

- pbxprojはファイルシステム同期グループを使っておらず手動登録が必要。
  新規Swiftファイルは `PBXFileReference` + 対象ターゲットごとの
  `PBXBuildFile` + 各グループ/Sourcesビルドフェーズへの追記が要る
  (このセッションでは重複ID発行を避けるためPythonスクリプトで機械的に追記)。
- **並行編集による巻き込みコミット**: このセッション中、別エージェントが
  同じリポジトリで高頻度にコミットしており、`git add` でステージした変更が
  タイミングによって別エージェントの無関係なコミットに巻き込まれる事象が
  複数回発生した(タスク1: `WatchAudioRoutePolicy` 一式が
  `3f6132c test: RequestPlaylistsWithArtwork...` に混入、タスク2:
  `WatchQueueView` 改名一式が `572457f feat: 曲リスト/MTP/歌詞メニュー...`
  に混入)。共有indexへの書き込みから commit 呼び出しまでの間隔を広げるほど
  リスクが増すため、以降は「編集直後に即 `git add` + `git commit` を
  1回のbash呼び出しで完結させる」方式に変更し、タスク3・4はクリーンに
  単独コミットできた。履歴の書き換え(rebase等)は他エージェントの作業を
  破壊するリスクが高いため行っていない。
