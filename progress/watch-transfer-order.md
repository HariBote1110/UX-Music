# iPhone→Watch転送で曲順が入れ替わる不具合の修正

## 真因（コード読解で特定）

Watch側の曲一覧は「アルバム名でグループ化し、各アルバム内はソートせず転送到着順をそのままトラック順とみなす」実装だった（`WatchAlbumGrouping.albums(from:)`、`WatchTransferMeta`にdisc/track番号フィールドが存在しなかったため）。

この「到着順＝トラック順」という前提は、オンデバイストランスコード機能（`WatchTransferBridge.performTransfer`）の導入で壊れていた：曲ごとに検出されずに個別の`Task`（実質デタッチ相当）でトランスコードを走らせていたため、複数曲のトランスコードが並行実行され、`session.transferFile`の呼び出し順（＝WatchConnectivityの配信順）がトランスコード完了順になっていた。短い曲ほど先に変換が終わるため、アルバム内の曲順がエンキュー順ではなく完了順にスクランブルされていた。

## 修正内容

### 1. トラック/ディスク番号を転送メタデータに乗せてソートする（恒久対応）

- `WatchTransferMeta`（`Core/WatchTransfer.swift`）に`trackNumber: Int?`・`discNumber: Int?`を追加。旧バージョンの送信側/永続化済みJSONとの互換のためoptional・デフォルトnil（Codable合成のデコードはキー欠如時に自動でnilになる、`fromWCMetadata`も欠如を許容）。
- `WatchTransferBridge.sendFile`で`Song.trackNumber`/`discNumber`から値を詰める。`Song`側はタグ無しの場合`0`がデフォルトなので、`0`は「未設定」としてnilに変換している。
- `WatchAlbumGrouping.albums(from:)`：アルバムバケット内を`sortedByTrackOrder`でソートするよう変更（disc→track、両方nilは`Int.max`扱いで最後に回り、同点はSwiftの安定ソートにより到着順を維持）。ドキュメントコメントの「到着順＝トラック順」という古い前提の記述も更新。

### 2. トランスコード→送信パイプラインをFIFO化する（並行性そのものを解消）

- `WatchTransferBridge`に`transferWorkQueue: [Song]`と`WatchTransferWorkQueue`（純粋なenqueue/dequeue関数）を追加。`performTransfer`は曲をこのキューに積むだけになり、実際のトランスコード＋送信は単一のドレインループ（`drainTransferWorkQueue`）が1曲ずつ完了を待ってから次に進む。
- これにより`transferFile`の呼び出し順は常にキュー投入順（＝アルバム内で送信を要求した順）になり、トランスコード所要時間に依存しなくなる。
- KVOによる進捗観測（`.sending(Double)`）とキューアイテムのフェーズ遷移（`.preparing`→`.sending`→`.sent`）は変更なし、ワーカーの内部構造だけを差し替えた。

### 3. Watch側インデックスの「再送で修復」を可能にする（仕様変更）

- `WatchLibraryIndex.adding`は従来「先着優先（first write wins）」で、既に受信済みの曲IDを再送しても何も更新されなかった。これだと修正前に転送済みの曲は永遠にtrack/discNumberを獲得できない。
- 同一idが既にある場合は**その位置のまま中身を更新**する仕様に変更。これは仕様変更であり、対応する既存テスト（`testAddingIsNoOpForDuplicateID`）も新仕様（`testAddingUpdatesExistingEntryInPlaceForDuplicateID`）にpinし直した（弱体化ではなく意図した挙動変更）。
- ユーザー向け案内：曲順が崩れているアルバムは、Watch設定から**そのアルバムを再送信**すれば、同じ位置のまま新しいtrack/discNumber付きメタデータで上書きされ、次回のアルバム一覧表示で正しい順序に修復される。

## 検証状況

- ロジックレベルの修正であり、実機のWatchペアリングはこの環境ではシミュレートできないため、UI上の実機確認は未実施。
- **実機での確認が必要**：曲順が崩れているアルバムを一度削除→再転送、または既存曲を再送信し、Watch側のアルバム内曲順が正しくなることを確認する。
