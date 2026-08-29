# Watch「曲」リストを開く際の遅延 — 既存調査の確認と追加検証の要否判断

## 目的 / 仮説
実機のApple Watch（50〜200曲規模）でLibraryの「Songs」行をタップしてから
フラット曲一覧が表示されるまで数秒かかる、という症状について、下記4仮説を
一変数ずつ検証する（当初の依頼内容）。

- A. `NavigationLink { songList } label: }` がLibraryページの各行描画のたびに
  destinationを**即時（eager）構築**しており、`songList`が`Array(order.songs
  .enumerated())`とForEachデータを毎回組み立てている
- B. `NavigationStack` pushそのもの（`ScrollView`+`LazyVStack`のN行が初回レイ
  アウトで想定より多く実体化される）
- C. 行ごとの`.contextMenu`のコスト
- D. 行ごとの`@EnvironmentObject player`監視によるN回のbody評価

## 環境
- リポジトリ: `/Users/yuki/GitHub/UX-Music`（現在ブランチ `main`）
- 対象ファイル: `UX-Music-Mobile/UX-Music-Watch/WatchSongListView.swift`,
  `UX-Music-Watch/WatchLocalLibrary.swift`

## 手順（今回のセッションで実施したこと）
新規にシミュレータ計測を組む前に、まず既存の研究記録
（`/Users/yuki/GitHub/UX-Music/progress/watch-ui-redesign.md`、
セクション「2.『曲一覧に入るのが死ぬほど重い』」）と現行コードの
doc commentを確認した。これは研究ワークフローの原則
「棄却済み仮説は再調査しない」「既存ノートを必ず先にチェックする」に基づく。

`git log --oneline -- WatchSongListView.swift WatchLocalLibrary.swift` で
該当調査のコミットが実際にmainへ既にマージ済みであることも確認済み
（`eabe02e` 「WatchLocalLibraryで曲一覧のソート/アルバム分類をsongs変更時に
1回だけ計算」、`9b9eb0f` 「曲一覧をListからScrollView+LazyVStackに変更」、
`debba2e` 「Watchのアートワーク行がメインスレッドで毎回デコードされていたの
を修正」）。

既存調査の計測条件: `sample <pid>`によるCPUプロファイリングと
`print`+`fflush(stdout)`による関数呼び出し回数の実測（計測コードはコミット
前に完全に削除済み）を、28曲・320曲（40アルバム×8トラック）の両方のシード
済みライブラリで実施。Apple Watch Series 11 (46mm) / SE 3 (40mm)、
watchOS 26.5 シミュレータ。

## 結果（既存調査からの引用・要約）

| 候補 | 検証方法 | 結果 |
|---|---|---|
| デコード同時実行数の爆発（本依頼のB/C/Dに近い「行あたりコスト」全般の代理指標） | `sample`でメインスレッド外を確認、`Task.detached`呼び出し回数を実測 | **棄却**。28曲・320曲いずれも同時実行1〜2件（画面内行数と一致）。watchOSの`List`は`UICollectionViewListCoordinatorBase`で遅延生成、`ScrollView`+`LazyVStack`化後も同様 |
| `songList`のbody評価毎の再ソート/再グルーピング（＝本依頼の**仮説A**そのもの） | `print`計測 | **確定**。ライブラリ画面表示時点で`NavigationLink(destination:label:)`のeager構築により、曲行を一度もタップする前に`songsSortedByAlbum`/`positions(forAlbumKeys:)`が**2回**呼ばれていた。320曲でも起動後0.1秒程度で完了 |
| 修正前後のメインスレッドCPU使用量（シミュレータ、6秒サンプリング） | `sample` | 修正前 177ms/6000ms、修正後 234ms/6000ms（誤差範囲、有意差なし） |

シミュレータ上では28曲・320曲いずれの規模でも「死ぬほど重い」体感速度の遅延
は**一度も再現できなかった**（Macホストの高速CPU上で実行しているため）。

## 結論
- **仮説A（NavigationLinkのeager destination構築 + `songList`内での毎回の
  ソート/グルーピング再計算）は確定・既に修正済み**。`WatchLocalLibrary`に
  `flatOrder`（`@Published`、`setSongs`内で一度だけ計算）を追加し、
  `songList`はこれを読むだけになっている（現行コード
  `WatchLocalLibrary.swift:63`, `WatchSongListView.swift:82`で確認）。
  ただし「NavigationLinkがdestinationをeagerに構築すること自体」は
  `songList`の`ForEach`データ組み立てコスト自体をゼロにはしない。
  `flatOrder`読み出し後の`Array(order.songs.enumerated())`は毎回のeager構築
  のたびに再生成されるが、これは配列のコピー＋enumerateのみで、既存計測が
  示す通り320曲でも実測不能なほど軽い。
- **仮説B（NavigationStack pushでの行の過剰実体化）は既存調査で棄却相当の
  証拠あり**。`sample`によるスレッド検査で`Task.detached`呼び出し数が画面内
  表示行数と一致しており、`List`（`UICollectionViewListCoordinatorBase`）も
  移行後の`LazyVStack`も遅延生成が機能している。本依頼が明示した「push時に
  評価されるWatchSongRow.body数」を直接カウントする計測は本セッションでは
  未実施（下記「次の一手」参照）だが、アートワークデコード呼び出し数という
  强い代理指標では棄却方向。
- **仮説C（`.contextMenu`のコスト）・仮説D（`@EnvironmentObject player`監視）
  は既存調査で個別に分離検証されていない**。ただし修正後のシミュレータ計測
  （234ms/6000ms、有意差なし）は、これらを含めた現行実装全体でも「死ぬほど
  重い」症状をシミュレータ上で説明できないことを示しており、これらが支配的
  要因である可能性は低いと考えられる（棄却ではなく未検証のまま保留）。
- **最重要の結論（既存調査より）**: シミュレータでは症状そのものが再現しな
  い。実機のCPU性能はMacホスト実行のシミュレータより大幅に低く、体感速度の
  差は主にCPU性能差そのものに起因する可能性が高い。実機計測なしでは確定的
  な残存原因の特定はできない、というのが既存調査の到達点であり、本セッショ
  ンで新たにシミュレータ実験を積み増しても同じ壁（Macホストが速すぎて再現
  しない）に当たる公算が高い。

## 次の一手 / 未検証事項
- **実機計測が必須**（既存調査時点から変わらず未実施。非対話セッションでは
  実機へ接続する手段がない）。次にユーザーが実機を用意できるセッションで、
  `os_signpost`をLibraryタップ→onAppearの区間に仕込み、Instruments経由で
  N=20/100/200の3水準×3回計測を行うこと。
- 仮説B/C/Dのうち「push時に実際に評価される`WatchSongRow.body`の回数」を
  staticカウンタで直接数える計測は未実施のまま。ただし優先度は低い —
  上記の通りアートワークデコード呼び出し数という強い代理指標で否定的な結果
  が出ている。
- 推奨する本番修正（実機計測で仮説Aの残存コストが有意と判明した場合の仕様）:
  `NavigationLink(destination:label:)`を`NavigationLink(value:)` +
  `.navigationDestination(for:)`に置き換え、destination構築を真に遅延評価
  にする。これにより`songList`（および`albumList`）のeager構築自体をなくせ
  る。ただし現時点のシミュレータ計測ではこの残存コストの実測値が取れていな
  いため、実装前に実機でのbefore/after計測を必須とする。
