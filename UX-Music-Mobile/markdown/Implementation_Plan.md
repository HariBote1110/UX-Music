# Implementation Plan: Wear API の mDNS 自動発見

## 方針
Desktop 側は既に Wear API と UX Sync API を同じ `:8765` で公開し、`_uxmusic-sync._tcp.local.` を広告している。Mobile 側ではこの広告を Wear API profile の発見にも使い、既存の `ServerConfig` と `WearAPIClient` をそのまま活かす。

## 実装ステップ
1. TXT / role / host / port の純ロジックを `WearDiscoveryPeer` として切り出し、単体テストで固定する。
2. `NetServiceBrowser` で `_uxmusic-sync._tcp.` を探索し、解決済み `NetService` から TXT record と host / port を得る。
3. Settings 画面に発見済み peer の一覧と再検索ボタンを追加する。
4. peer 選択時に `ServerConfig` へ保存し、既存 `/wear/*` 導線がそのまま使えるようにする。
5. `Info.plist` / build settings に `NSBonjourServices` と local network usage description を揃える。
6. Wear API の `URLSession` を LAN 専用設定にし、system proxy / iCloud relay / cellular fallback を無効化する。
7. Settings 表示時の mDNS listener は維持しつつ scan indicator timeout を設け、到達不能時の LAN HTTP timeout も短くする。
8. 発見した peer の複数 IPv4 候補を保持し、Settings の `Test` では手動入力 host から順に候補を試して、最初に成功した host を `ServerConfig` に保存する。

## 検証
- `WearDiscoveryPeerTests` で TXT 正規化と Wear API 候補判定を確認する。
- `WearDiscoveryPeerTests` で複数 IPv4 候補の保持と接続候補の重複排除を確認する。
- `WearDiscoveryPeerTests` で scan timeout 後に探索中表示だけが消え、mDNS listener は維持されることを確認する。
- `WearAPIClientTests` で LAN 専用 `URLSessionConfiguration` が proxy と cellular fallback を使わないことを確認する。
- `WearAPIClientTests` で通常の Wear API LAN HTTP timeout が短時間に制限されることを確認する。
- `UX_MUSIC_REAL_DEVICE_DISCOVERY_TEST` を付けた実機 XCTest で、同一LAN上の UX Sync mDNS peer を発見できることを確認する。
- `UX-Music-Mobile` scheme の iPhone simulator test を実行する。
