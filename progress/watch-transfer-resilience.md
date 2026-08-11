# 実機報告「アプリを閉じると転送が止まる」への対処

## ユーザー報告

「アプリ閉じちゃうと転送止まっちゃう。画面OFFになったあと勝手に文字盤に戻っちゃって転送が止まるのが複数回あった」

2つの独立した問題が混ざっている:

1. **Watch側**: 画面OFF後、watchOSが文字盤に自動的に戻ると、frontmost状態に依存する
   `WCSession`のファイル配信が止まる。
2. **iPhone側**: 転送キューがメモリ上のみ（`WatchTransferBridge.queue`/`transferWorkQueue`）に
   存在していたため、iPhoneアプリを終了すると未転送の曲の情報自体が失われる。

## watchOSの配信リアリティ（frontmost依存）

`WCSession.transferFile`はキュー投入のみを保証する非同期APIで、実際のバイト転送は
watchOSがWatchアプリをアクティブ（frontmost）とみなしている間しか進行しない。画面OFF後、
「画面OFFで前回のアプリ表示を保持」設定の猶予時間（既定2分）を過ぎると文字盤に戻り、
配信が事実上止まる。

### 対処1: `isFrontmostTimeoutExtended`（`UX-Music-Watch/UXMusicWatchApp.swift`）

アプリ起動時に`WKExtension.shared().isFrontmostTimeoutExtended = true`を設定し、猶予を
2分から8分に延長を試みる。

**限界**: WatchKitのヘッダーで`WK_DEPRECATED_WATCHOS(4.0, 7.0, "No longer supported")`と
明記されており、watchOS 7以降Appleがこの挙動を保証しなくなった（本プロジェクトの
`WATCHOS_DEPLOYMENT_TARGET`は10.0）。有効な代替APIも存在しない
（`WKExtendedRuntimeSession`はワークアウト/マインドフルネス等の限定用途で汎用転送には
使えない）。したがって「効くかもしれないが保証はしない」ベストエフォート策であり、
恒久対策ではない。

## iPhone側キューの永続化（`Services/WatchTransferBridge.swift`）

`.sent`/`.failed`以外のキューアイテム（`.downloading`/`.waiting`/`.preparing`/`.sending`）を
UserDefaults（`AppConstants.watchTransferPendingQueueKey`）にid+titleだけのスナップショットで
保存し、次回`activate()`完了時に復元する。

### 純粋関数（TDD）

- `WatchTransferQueuePersistence.pendingSnapshot(from:)` — 永続化対象のサブセット抽出
- `WatchTransferQueuePersistence.shouldPersist(current:lastPersisted:)` — 差分が無ければ
  書き込みをスキップ（`.sending(fraction)`のKVO更新は高頻度なので、書き込み判定を分離）
- `WatchTransferRestoreReconciliation.plan(persisted:outstanding:downloadedSongIds:)` —
  永続化されたエントリを3種類に振り分け:
  1. `WCSession.outstandingFileTransfers`に生存している → 進捗監視を再アタッチ
     （outstanding優先。ダウンロード済みでも再送はしない）
  2. ダウンロード済みだが送信中でない → FIFOワークキューに**永続化順**で再投入
     （`watch-transfer-order.md`の曲順修正がリロード後も壊れないようにするため、順序保持は
     この関数のテストで明示的にピンしている）
  3. どちらでもない（アプリが閉じている間にローカルファイルが削除された等） → `.failed`

薄い配線側（`WatchTransferBridge`本体）は、この`Plan`を`WCSession`/`DownloadManager`の実データで
埋めるだけ。`sendFile`のトラッキング処理（`activeTransfers`/`transferObservations`登録）は
`trackTransfer(_:songId:)`として切り出し、新規送信と復元後の再アタッチの両方から使う。

### 「Watchに既に届いているか」を別途確認しない理由

`WatchLibraryIndex.adding`は既存idの再送を「同じ位置のまま上書き」する仕様
（`watch-transfer-order.md`参照）なので、復元後に念のため再送しても重複エントリにはならない。
そのためこの実装ではWatch側の状態を別途クエリしていない。

## UI: 転送中フッターヒント（`Views/WatchTransferQueueSection.swift`）

`WatchTransferHintPolicy.shouldShowFrontmostHint(items:)`が`true`（`.preparing`/`.sending`が
1件でもある）の間だけ、Settingsの転送キューセクションにフッターで案内を表示:
Watchアプリを開いたままにする・長時間の一括転送では「設定 > 一般 > 時計に戻る」を
カスタム(1時間)にする・充電とWi-Fiで速くなる、の2行。`.waiting`/`.downloading`のみの間は
まだ何も送信されていないため表示しない。

## 恒久対策ではない理由

上記3つはいずれも「watchOSのfrontmost依存という制約の中で被害を減らす」対症療法。
frontmost状態に依存しない転送手段（Watch自身がバックグラウンド`URLSession`でLAN経由
直接ダウンロードする方式）が本来の恒久対策であり、
`watch_transfer_research/notes/watch-direct-download-plan.md`に計画がある（未着手）。
