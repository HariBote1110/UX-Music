# タスク: Wear API の mDNS 自動発見

## 目的
UX-Music-Mobile が手動 host / port 入力や QR ペアリングだけに頼らず、Desktop 側の `_uxmusic-sync._tcp.local.` mDNS 広告から Wear API 対応 peer を自動発見できるようにする。

Wear API は廃止せず、UX Sync Protocol の lightweight mobile / wearable profile として扱う。Mobile App は発見した peer を既存の `ServerConfig` に変換し、従来どおり `/wear/*` で Remote Library / Remote Control / playlist import を利用する。

## 受け入れ条件
- `_uxmusic-sync._tcp.local.` の TXT から `deviceId` / `displayName` / `protocolVersion` / `schemaVersion` / `roles` を読めること。
- `LibraryHost` または `WearHost` role を持つ peer を Wear API 候補として扱い、互換性のため role が欠けた `_uxmusic-sync._tcp.local.` 広告も候補に含めること。
- 発見した peer の host / port を `ServerConfig` に変換できること。
- `NetService.addresses` から数値IPv4が得られる場合は、`.local` host名ではなく数値IPv4を `ServerConfig` に保存すること。
- `NetService.addresses` に複数の数値IPv4が含まれる場合は候補を保持し、Settings の接続テストでは手動入力値を先頭にしつつ、到達できる候補へフォールバックして成功した host を保存すること。
- Wear API の LAN HTTP 通信は system proxy / iCloud relay / cellular fallback を使わず、発見した同一LAN IPへ直接接続すること。
- Settings 表示時の mDNS listener は画面表示中維持しつつ、探索中表示だけは短時間で消えること。
- 通常の Wear API LAN HTTP 通信は到達不能な Desktop に対して長時間ハングせず、短時間で失敗扱いにできること。
- 実機で明示的に有効化した診断 XCTest から、同一LAN上の `_uxmusic-sync._tcp.local.` peer を発見できること。
- Settings 画面に発見済み Desktop 一覧が表示され、選択すると既存の host / port 設定へ保存されること。
- iOS の local network / Bonjour 許可に必要な `NSBonjourServices` が設定されていること。

## 非目標
- `/sync/*` の6桁コードペアリングや sync token 保存。
- `/sync/library/snapshot` による選択同期。
- Mobile 側で HTTP server を立てること。
