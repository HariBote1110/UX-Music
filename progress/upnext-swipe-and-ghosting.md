# Up next パネル: スワイプ削除の廃止とキュー行の「残像」修正

## 背景（実機報告2件）

1. Now Playing 画面の「Up next」パネルは横スワイプでプレイヤー本体へ戻れる（`page`
   バインディングによる横スワイプページング）。同じ画面で行スワイプ削除
   （`.onDelete`）も有効になっていたため、行内の横スワイプ操作がパネル自体の
   横ページングジェスチャーと同じ方向のドラッグを取り合っていた。
2. 「リストの描画に古いバージョンの面影が出てくる」＝キューを編集した際に
   古い内容が一瞬描画される「残像」現象。

## 決定: スワイプ削除を廃止しコンテキストメニューへ統合

ジェスチャー競合はユーザー判断により「行スワイプ削除を廃止し、長押しの
コンテキストメニューに統合する」で解決した。並べ替え（`.onMove`、既存の
「並べ替え」編集モード）はそのまま残す。

`NowPlayingQueuePanel`（`UX-Music-Mobile/Views/NowPlayingView.swift`）から
`.onDelete` を削除し、既存の `.contextMenu`（`WatchTransferSongMenuItem`を
表示していた箇所）に「キューから削除」（destructive、trash アイコン）を
追加した。

## 「残像」の真因（確認済み）

行の `Identifiable` な `id` が `"\(song.id)#\(offset)"`（配列オフセット直結）
だったこと。削除・並べ替えのいずれでも、対象より後ろにある行はすべて
オフセットが変わる＝行 `id` が変わる。SwiftUI の `ForEach` は `id` の一致で
「同じ行」と判断して位置アニメーションを行うが、`id` が変わった行は
「古い行が消える／新しい行が現れる」という別イベントとして扱われ、
デフォルトの transition（opacity）でクロスフェードする。これが並べ替え・
削除のたびに後続行がまとめて作り直され、古い内容が一瞬透けて見える
「残像」の実体。

検証: `MusicPlayerService.moveQueueItem`/`removeQueueItem` 自体は
`playbackQueue`（`queue`配列）を同期的に書き換えており、非同期ギャップが
主因ではなかった（`removeQueueItem`は`@MainActor`でawaitが必要になるのは
「削除した項目が再生中だった場合の`loadActive`呼び出し」のみで、削除
そのものはawait前に完了する）。真因は一貫してID設計側にあった。

なお `.onDelete` 側は複数選択削除で `offsets.sorted(by: >)` の各要素ごとに
`Task { await ... }` を個別発火しており、実行順序の保証がない
（先行Taskの完了でキューが変化した後に、後続Taskが変化前のindexを使って
削除する可能性がある）レースも内包していた。今回の対応でスワイプ削除自体を
廃止したためこのレースは経路ごと消滅している。

## 修正: 出現回数ベースの安定ID

`PlaybackQueueEditing.occurrenceIdentities(for:)`
（`UX-Music-Mobile/Core/PlaybackQueueEditing.swift`）を追加。
曲IDの配列を受け取り、各要素を `"<id>#<出現回数>"` にマップする純粋関数。
「それより前に同じidが何回出たか」だけを見るため、他の行の削除・並べ替えでは
自分のidは変わらない。同じ曲がキューに重複している場合のみ、前方のコピーが
消えると残ったコピーのidが1つ前倒しになる（＝消えた方が使っていたidを
引き継ぐ形になり、一貫性は保たれる）。

`NowPlayingQueuePanel.rows` はこの関数でIDを生成するように変更。
コンテキストメニューの削除ボタンはタップ時に `queue` の現在の並びから
`row.id` を検索してindexを引き直す（`removeFromQueue(rowId:)`）。長押し中に
別経路でキューが変化していても、開いた瞬間の `row.index` を鵜呑みにしない。

## 他画面への波及確認

- Favourites パネル（`NowPlayingFavouritesPanel`）は `ForEach(songs)` で
  `Song.id` を直接使っており、オフセット合成をしていない。お気に入りに
  同一曲が重複登録されることもないため、同じ不具合は再現しない。据え置き。
- Watch側のキュー表示（`WatchQueueVolumeView`）も `ForEach(player.playbackQueue)`
  で `WatchTransferMeta` を直接渡しており、オフセット合成なし。対象外。

## テスト

`PlaybackQueueEditingTests.swift` に `occurrenceIdentities` のテストを追加:
重複曲でのID一意性、無関係行の削除に対する安定性、並べ替えに対する安定性、
重複の片方削除時に残存側が一貫したIDを引き継ぐこと。
