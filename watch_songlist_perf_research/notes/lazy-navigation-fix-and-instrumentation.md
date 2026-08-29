# Watch「曲」リストを開く際の遅延 — 遅延ナビゲーション化の実装とDEBUG計測の追加

## 目的

`songlist-open-delay-prior-investigation.md`の「次の一手」で推奨された本番修正
（`NavigationLink(destination:label:)`→`NavigationLink(value:)` +
`.navigationDestination(for:)`への置き換え）を実装し、ユーザーの次回実機実行で
before/after の実測値を取るための計測コードを仕込んだ。

## 変更内容

対象: `UX-Music-Mobile/UX-Music-Watch/WatchSongListView.swift`

- `WatchLibraryDestination`（`.songs`/`.albums`/`.playlists`）を追加し、Library
  画面の3行を`NavigationLink(value:)` + 単一の
  `.navigationDestination(for: WatchLibraryDestination.self)`に置き換えた。
  これにより`songList`/`albumList`/`WatchPlaylistListView`はLibrary画面の
  描画時ではなく、行が実際にタップされた時点で初めて構築される。
- `albumList`のアルバム行も同様に`NavigationLink(value: album)` +
  `.navigationDestination(for: WatchAlbumGroup.self)`へ置き換えた。
  `WatchAlbumGroup`（`Core/WatchPlaybackLogic.swift`）と、そのプロパティ型
  `WatchTransferMeta`（`Core/WatchTransfer.swift`）に`Hashable`適合を追加
  済み（全ストアドプロパティがHashable互換の値型のため、コンパイラ合成の
  みで対応可能だった）。
- 3箇所の`NavigationLink(destination:label:)`のeager構築を説明していた
  doc commentを、新しい遅延構築の仕組みを説明する内容に更新した
  （`WatchSongListView`型ヘッダ、`songList`のポイント2、`albumList`）。

## DEBUG限定計測（`#if DEBUG`、Releaseビルド非含有）

`WatchSongListPerfLog` / `WatchSongRowPerfCounter`（同ファイル内）が
`[WatchSongListPerf]`プレフィックス付きでXcodeコンソールに出力する:

1. **Songsタップ時刻** — `Songs`行の`NavigationLink`に付けた
   `.simultaneousGesture(TapGesture())`から`WatchSongListPerfLog
   .songsLinkTapped()`を呼び、タップされた瞬間（`.navigationDestination`が
   `songList`を構築する前）のt+msを出力。
2. **曲一覧の初回レイアウト完了時刻** — `songList`の`ScrollView`に
   `.onAppear`を追加し、`WatchSongListPerfLog
   .songListFirstLayoutAppeared(songCount:)`を呼ぶ。t+msと曲数、および
   その時点までの`WatchSongRow.body`評価回数（3.参照）を出力。
3. **`WatchSongRow.body`評価回数** — `WatchSongRowPerfCounter`
   （プロセス全体のstaticカウンタ）を`WatchSongRow.body`の先頭でインクリ
   メント。2.のonAppear時点の値と、その1秒後（`Task.sleep`）の値の両方を
   出力するので、初回pushで実体化された行数とスクロール操作で追加実体化
   された行数の差が読み取れる。

## 検証

- ビルド: `xcodebuild -scheme UX-Music-Watch -destination 'generic/platform=watchOS
  Simulator' -derivedDataPath UX-Music-Mobile/.tmp/dd3 build` → **BUILD SUCCEEDED**。
- シミュレータでは既存調査の通り体感遅延自体が再現しないため、before/after
  の数値比較はシミュレータでは意味を持たない。**実機での計測が未実施**
  （このセッションでは実機に接続する手段がない）。

## ユーザーの次回実機実行で読むべきコンソール行

Xcodeを実機に接続してWatchアプリを実行し、Libraryの「Songs」をタップした
直後のコンソールで、以下の3行（プレフィックス`[WatchSongListPerf]`）を確認する:

```
[WatchSongListPerf] Songs link tapped at t+<A>ms
[WatchSongListPerf] Song list first layout appeared at t+<B>ms, songCount=<N>, WatchSongRow.body evaluations so far=<C>
[WatchSongListPerf] +1s after first layout: WatchSongRow.body evaluations=<D>
```

- `<B> - <A>` が「タップしてから曲一覧の初回レイアウトが終わるまで」の実測
  遅延（ms）。今回の修正が効いていれば、修正前に報告されていた「数秒」より
  大幅に短くなっているはず。
- `<C>`は初回レイアウト完了時点で実体化済みの行数の目安、`<D>`はその1秒後
  （多くの場合ユーザーがまだスクロールしていない状態）の値。両者がほぼ
  画面内表示行数と一致していれば、`ScrollView`+`LazyVStack`の遅延生成は
  実機でも機能している。

50曲・100曲・200曲規模のライブラリで、それぞれ複数回タップして`<B> - <A>`
を記録し、既存の「数秒」という体感と比較するのが望ましい。

## 追記: 遅延ナビゲーション仮説の棄却とLLDBによる真因特定

上記の計測コードを実機に仕込んだ状態でユーザーに実行してもらったところ、
`[WatchSongListPerf]`のログは次のように出た。

- `Songs link tapped at t+0ms` → ほぼ同時刻に
  `Song list first layout appeared at t+0ms`（タップから初回レイアウトまで
  ほぼ0ms）。
- `WatchSongRow.body`評価回数は初回レイアウト時点で6件（画面内表示行数相当）
  で、1秒後も増えていない。

つまり「`NavigationLink(destination:label:)`のeager構築で画面外の行まで
一括生成されている」という遅延ナビゲーション仮説は**棄却**された。
`.navigationDestination`によるlazy化後もSwiftUI側のレイアウト・行の実体化
は一瞬で終わっており、それにもかかわらずユーザー体感のフリーズ（数秒間
操作不能）は解消していなかった。

そこでユーザーの実機にXcodeをアタッチしてLLDBでフリーズ中のバックトレース
を採取したところ、真因は`WatchAlbumGroupConnectorView`（本ファイル内、
アルバムのまとまりを示す縦線＋elbowを描く箇所）で使っていたSwiftUI
`Canvas`だった。`Canvas`の初回描画がメインスレッド上で同期的に
RenderBox描画用ビューを生成し、その過程で`MTLCreateSystemDefaultDevice`
の呼び出しとMetalプラグインバンドルの`dlopen`が走る。watch実機ではこれが
数秒かかり、さらにXcodeデバッガ接続下ではdyldの`notifyDebuggerLoad`通知
がこれを輪をかけて遅くしていた。Watchターゲット内で`Canvas`を使っている
箇所はここ1箇所のみ（grep確認済み）。

対応として`WatchAlbumGroupConnectorView`の実装を`Canvas`から、
`Shape`に適合する`WatchAlbumGroupConnectorShape`（`path(in:)`で
`AlbumGroupConnector.verticalSegment(for:rowHeight:artworkSize:)`と
`AlbumGroupConnector.hasElbow(for:)`という既存の純粋ジオメトリ関数を
そのまま再利用）に置き換えた。ストロークのスタイル
（`Color.secondary.opacity(0.35)`、lineWidth 1）と`.frame(width:
WatchSongRowMetrics.artworkSize)`は変更していないため見た目は同一のはず。
Metal/RenderBoxの初期化を経路上から完全に排除できる。

この置き換えについての**実機での確認は未実施**（このセッションでは実機に
接続する手段がない）。次回の実機実行では、`[WatchSongListPerf]`計測は
そのまま残してあるので、`Songs`タップ直後の体感フリーズが解消しているか
どうかを目視で確認しつつ、念のため上記3行のログも引き続き記録してほしい。
