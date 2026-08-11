# Watch 直接ダウンロード（LAN 経由）計画 — 未着手

## 目的 / 仮説

WCSession transferFile の実効帯域（BT 経由 約 50〜100 KB/s、OS 管理で制御不可）を回避し、
Watch 自身が `URLSession` でデスクトップサーバから AAC 128kbps を直接ダウンロードすることで
Wi-Fi Mbps 級（4MB ≈ 数秒）の転送を実現する。

仮説: **iPhone 近接時（companion BT プロキシ経由にルーティングされる場合）でも、直接 DL は
WCSession transferFile より速い**。Wi-Fi 直結が使われる条件（バックグラウンド URLSession +
充電中、または iPhone 遠隔）では 1 桁以上速い。

反証条件: 実機計測で iPhone 近接時のスループットが WCSession 比 1.5 倍未満、かつ Wi-Fi 直結
条件が日常利用で成立しにくい（充電器必須が UX として許容できない）場合は棄却。

## 前提（既存資産 — 追加実装がほぼ不要なもの）

- サーバ: `/v1/remote/file`（`source=original` なし）が既に AAC 128kbps m4a を返す
  （`server/app_remote.go` `getOrTranscode`、`RemoteCache/` にキャッシュ済み）
- 認証: deviceAuthTokens（/v1/remote・/v1/sync の LAN API v1 統一に準拠）
- Watch 側: `AVPlayer` 再生・`WatchAudioStorage`・`WatchLocalLibrary`（受信後の保存/索引は
  WCSession 受信と同じ経路に合流できる）
- iPhone 側: `RemoteConnectionResolver` / `LANDiscoveryService` が接続先解決済み
  → 解決済みアドレス+トークンを `WCSession.updateApplicationContext`（数百バイト）で Watch に
  常時同期すれば、Watch 側でのサーバ発見（Bonjour）は不要

## フェーズ 0: research（実機計測）— 着手判断のゲート

1. Watch に最小 DL プローブを実装（指定 URL を 1 本 DL して所要時間・バイト数をログ）
2. 条件マトリクスで計測:
   - {iPhone 近接 / iPhone 遠隔(電源断)} × {前面 URLSession / バックグラウンド URLSession} × {充電中 / 非充電}
3. 比較基準: 現行 WCSession transferFile の実測スループット
   （`WatchTransferBridge` / `WatchConnectivityReceiver` に転送時間ログを仕込み、実機報告から回収 —
   これはトランスコード効果の実測にも使えるので先行投入する価値あり）
4. 採択基準: 日常条件（iPhone 近接・非充電）で 3 倍以上、または「充電中に一括同期」UX を
   許容するなら Wi-Fi 直結条件で 10 倍以上

結果は `watch_transfer_research/notes/` に記録してから着手判断。

## フェーズ 1: 最小実装（採択時）

- iPhone → Watch: `applicationContext` でサーバ候補（host/port/token/有効期限）を同期
- Watch: `WatchRemoteDownloader`（バックグラウンド `URLSession`、完了時に
  `WatchAudioStorage` へ移動 + `WatchLocalLibrary.addSong` — WCSession 受信と同一の合流点）
- 経路選択: まず LAN 直接 DL を試行 → 失敗/タイムアウト → 現行 WCSession transferFile
  （トランスコード済 AAC）へフォールバック。ユーザーに経路を意識させない
- アートワークも同様に直接 DL（`/v1/remote/artwork` 既存）

## フェーズ 2: 統合（任意）

- project_sync の「DL 優先シームレス化」と整合させ、Watch を sync クライアントの一種として扱う
- iPhone 側転送キュー UI に Watch 直接 DL の進捗を反映（`sendMessage` で進捗返し）

## リスク / 未知

- **watchOS のルート選択は強制不可**: iPhone 近接時は BT プロキシに落ち得る（フェーズ 0 で判定）
- Watch の Wi-Fi は既知ネットワーク限定、Series 5 以前は 2.4GHz のみ
- watchOS のバックグラウンド URLSession は復元・実行時間に制約（充電中が最も安定）
- 曲の同一性: 直接 DL(m4a) と WCSession 転送(m4a/原本) が同じ `storedFileName` 規約に
  合流するため二重取得は自然に冪等になる想定だが、fileType 不一致（旧 flac 転送済み曲）は
  「first write wins」により残存 → 再送 UX と合わせて要検討

## 採択理由の追記（実機報告が後押し）

実機報告「アプリ閉じちゃうと転送止まっちゃう。画面OFFになったあと勝手に文字盤に戻っちゃって
転送が止まる」への対処として `progress/watch-transfer-resilience.md` で対症療法3件
（Watch側 `isFrontmostTimeoutExtended`・iPhone側キュー永続化・UI案内）を実装したが、
この過程で `isFrontmostTimeoutExtended` がwatchOS 7以降 `WK_DEPRECATED_WATCHOS(..., "No longer
supported")` と判明し、frontmost依存を軽減する現実的なAPIが存在しないことが確定した。
つまり `WCSession.transferFile` を使う限り「アプリを開いたままにしてもらう」以上の対策は
watchOS側には無い。この報告は、本計画が想定していた「WCSessionはfrontmostに依存するが
バックグラウンドURLSessionは仕様として起動suspend後も継続する」という差を、実際のユーザー
体験として裏付ける具体的な駆動要因になった。着手判断（フェーズ0計測）の優先度を上げる根拠として記録する。

## 関連

- ボトルネック調査と AAC128 採択: [watch-transfer-bottleneck.md](watch-transfer-bottleneck.md)
- 実機報告への対症療法3件（本計画着手までの緩和策）: [watch-transfer-resilience.md](../../progress/watch-transfer-resilience.md)
