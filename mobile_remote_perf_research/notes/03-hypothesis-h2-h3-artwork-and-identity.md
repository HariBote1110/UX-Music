# H2/H3: アートワークの再デコードとグリッドID安定性（静的解析）

## 目的 / 仮説

- H2: `RemoteArtworkPreviewCache`/`ArtworkImageView`が再描画のたびにリモート
  アートワークを再フェッチ・再デコードしていないか（`task(id:)`キーの不安定さ、
  キャッシュミス、小タイル用のフルサイズデコード）。
- H3: `RemoteLibraryScreen`の`NavigationStack`+`LazyVGrid`が、`id:`が不安定な
  キーのために行を再生成していないか。

計測環境のビルド往復コストが高いため、本ノートはコード読解による静的解析のみ。
実行時計測は「次の一手」に委ねる。

## 環境

対象ファイル: `UX-Music-Mobile/UX-Music-Mobile/Services/RemoteArtworkCaching.swift`・
`Views/ArtworkImageView.swift`・`Views/RemoteLibraryScreen.swift`
（コミット`31ccd80`時点）。

## 結果（コード読解）

### H2: アートワーク

- `ArtworkImageView.taskIdentity`は`"\(artworkId)\u{1E}\(urlString)"`で、
  `artworkId`/`urlString`が変わらない限り`.task(id:)`は再実行されない。
  **同一ビューインスタンスが再描画されるだけでは再フェッチは起きない** —
  「再描画のたびに再フェッチ」という仮説の狭い意味（同一ビューでの反復）は
  棄却。
- `RemoteArtworkFetchCoordinator`（actor）が`artworkId`/`urlString`をキーに
  in-flightな`Task`を共有しており、同時に複数箇所から同じ画像を要求しても
  HTTPリクエストは1本に集約される。二重フェッチという意味でも棄却。
- ただし**「ビューが再生成される」ケース**（`LazyVGrid`のスクロールでセルが
  画面外に出て再利用される、あるいは`ForEach`のidが変わって新しい
  `ArtworkImageView`インスタンスが作られる場合）では`@State private var
  loaded`がリセットされ、`.task(id:)`が最初から走る。ディスクキャッシュ
  (`RemoteArtworkPreviewCache`)にヒットする限りHTTPは飛ばないが、
  `UIImage(contentsOfFile:)`によるデコードは**毎回フルサイズで**行われる
  （`wearRemoteArtworkLoadDirect`、`Services/RemoteArtworkCaching.swift`
  85〜87行目付近）。`ArtworkImageView`は`size: CGFloat? = 48`のグリッド用
  小タイルでも、`.resizable().aspectRatio(contentMode: .fill)`で表示サイズに
  縮小するだけで、**デコード自体を縮小するAPI
  （`UIImage.preparingThumbnail(of:)`や`CGImageSourceCreateThumbnailAtIndex`
  のダウンサンプリング）は使っていない**。500曲・複数アルバムのグリッドを
  スクロールで往復すると、セル再利用のたびにフル解像度画像のデコード
  （CPU・一時メモリ確保）が繰り返される可能性がある。
  → **「小タイル用のフルサイズデコード」は実装を読んだ限り事実**（採択）。
    ただし本ノートでは実際のCPU/メモリへの寄与度を計測していない
    （次の一手）。

### H3: グリッド行のID安定性

`RemoteLibraryScreen.swift`のForEachを確認:

| 箇所 | 行 | ID指定 | 安定性 |
|---|---|---|---|
| Playlistsグリッド | 367 | `ForEach(Array(rows.enumerated()), id: \.offset)` | **不安定**（配列インデックス） |
| Albumsグリッド | 431 | `ForEach(albums)`（`Album: Identifiable`前提） | 安定 |
| Songsリスト | 488 | `ForEach(Array(songs.enumerated()), id: \.element.id)` | 安定（`song.id`） |

Playlistsグリッドのみ`id: \.offset`で、`remotePlaylistRows`が並べ替え・挿入
されるとSwiftUIは同じインデックスの要素を「同じ行」とみなして誤った差分更新
（アニメーションの誤爆や不要な子ビュー再生成）をする可能性がある。ただし
`remotePlaylistRows`は`.task(id: viewMode)`で一度ロードされたら`viewMode`が
`.playlists`のままである限り再代入されない（99行目）ため、**アイドル時や
Songs/Albums間のページングでは影響しない** — 「ページング中に高頻度で
行が再生成される」という当初のH3の主眼（`LocalLibraryScreen`と同型の問題）は
棄却。Albums/Songsは安定IDなので同様に棄却。

## 結論

- H2は**部分採択**: 再フェッチ・二重フェッチは棄却。ただし「小タイルでもフル
  解像度デコード」は実装上の事実で、スクロール中のCPU/メモリコストに寄与しうる
  （未計測）。
- H3は**棄却**（Playlistsの`id: \.offset`という軽微な脆弱性は残るが、現状の
  ロード契機ではページング中の高頻度再構築を引き起こさない）。

## 次の一手 / 未検証事項

- 500曲グリッドを連続スクロールさせた際のCPU/メモリを実測し、H2のフルサイズ
  デコードコストを定量化する（タッチ自動化の座標系整備が必要、本タスクの
  時間内では未実施）。
- `ArtworkImageView`に`UIImage.preparingThumbnail(of:)`（表示`size`ベース）を
  導入した変種で同条件のスクロールCPU/メモリを比較する。
- Playlistsグリッドの`id: \.offset`を`pl.id`相当の安定キーに直す修正は、
  現状computedされる実害が無いため優先度は低いが、`remotePlaylistRows`の
  更新契機が将来変わった場合に備えて`/development`フローでの修正候補としては
  残す。
