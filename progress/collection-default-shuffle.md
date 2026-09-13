# アルバム/プレイリストごとの既定シャッフル（Desktop・iOS）

## Decision
- アルバム・プレイリストごとに既定シャッフルを「未設定／シャッフル／順番通り」の3状態で持つ。
- **基準値（baseline）** ＝ユーザー自身のシャッフル設定（Desktop: settings.json `isShuffled`、iOS: UserDefaults `uxmusic.playback.shuffleEnabled`）。プレイヤーのシャッフルボタンだけが変更・永続化する。
- 新しいキューをコレクションから開始したときだけ、既定値があればそのキューに一時適用する（永続化しない）。未設定のコレクションやコレクション外（曲一覧など）から新規キューを始めたら基準値に戻す。
  - ユーザー要望「そのアルバムの再生中だけ」を実現するための方式。
- キュー内移動（次/前・キュー項目クリック）ではシャッフルを変えない。
- 上書き中にシャッフルボタンを押したら、それが新しい基準値になり永続化される（明示操作を尊重）。
- Desktop と iOS の設定は同期しない（端末ごと）。リモート API は無変更。
- Desktop: Go 側 `collection-shuffle.json`（キー `album:<albumKey>` / `playlist:<名前>`）。Go キューには `QueueSetWithShuffle` を追加し、キュー差し替えとシャッフル状態を1回のロックで確定させる（QueueSetShuffle→QueueSet の二段階だと二重シャッフルと中間状態通知が出るため）。
- iOS: `CollectionShufflePreferenceStore`（UserDefaults JSON）。キーはアルバム=Album.id、ローカルプレイリスト=UUID、デスクトッププレイリスト（ライブ閲覧）=名前。`MusicPlayerService.play(_:newQueue:collection:)`。

## Alternatives considered
- 適用したらシャッフルボタンの状態をそのまま保存する方式 → ユーザーが「再生中だけ」を選択したため不採用。
- Desktop の設定を `/v1/remote/playlists` で iOS に配信 → 変更範囲が大きく、名前でしか対応付けできないため今回は見送り。

## Constraints / Gotchas
- Desktop のプレイリストは名前がキー。Go の RenamePlaylist/DeletePlaylist で設定を移動/削除し、renderer は `musicApi.renamePlaylist/deletePlaylist` 後にキャッシュを再読込する。
- アルバムはタイトル由来のキーなので、同名アルバム（別アーティスト）は設定を共有する（Desktop・iOS 共通の既存制約）。
- Desktop `state.isShuffled` は Go キューのライブ状態の写し。基準値は playback-manager.ts の `baselineShuffle` に別管理。
- iOS `isShuffleEnabled` もライブ状態で、`baselineShuffleEnabled` が永続値。MusicPlayerService は TV ターゲットでもコンパイルされるため、新規ファイルは TV ターゲットにも追加が必要。
