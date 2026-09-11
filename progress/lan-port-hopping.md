# LAN サーバーのポートホッピングと確保失敗の可視化

## 背景（根本原因）
- 2026-09-12、LAN 内の iPhone から Desktop に接続できなくなった。原因は別プロジェクト（Glow の `glow-sender serve 8765`）が 8765 を先に使っていたこと。
- `StartLANServer` は `ListenAndServe` の失敗をログに出すだけで起動を続けていた。そのうえ mDNS は 8765 を告知し続けたため、クライアントは別アプリにつながり、画面には何のエラーも出なかった。

## Decision
- 候補ポートは 8765〜8774 とし、8765 を優先して昇順に試す。`net.Listen` で同期的に確保し、実際に確保したポートを実行時の状態として持つ。
- ペアリング URL、`GetLANServerAddress`、sync の baseURL、mDNS 告知は、定数ではなく実際に確保したポートを使う。
- どの候補も確保できなかった場合は mDNS を告知しない（自分が持っていないポートを告知しない）。起動は続けるが、`GetLANServerStatus` とイベント `lan-server-status` でデスクトップ UI に知らせる。
- GUI 起動時の handoff は、候補ポートすべてを並行して probe し、常駐 `--serve` がどのポートにいても引き継げるようにする。HTTP に応答しないプロセスがいても、起動の遅れはタイムアウト 1 回分に抑える。
- 保存済みの接続先（Desktop 間の `syncKnownPeers`、iOS/TV の `ServerConfig`）は、保存ポートにつながらなければ候補ポートを探索する。採用するのは `/v1/identity` の deviceId がペア相手と一致した場合だけとし、見つかったポートは保存し直す。iOS/TV は mDNS による再解決を先に試す。

## Alternatives considered
- 前回確保したポートを優先する方式：ポートを安定させる効果はあるが、8765 が空けば毎回 8765 に戻る昇順方式でも実用上は十分安定する。保存状態が増えるので採用しなかった。
- OS 任せの空きポート（`:0`）：mDNS に頼れない保存済み接続や手入力の探索範囲が決まらなくなるため不採用。
- deviceId を照合せずにポートだけ探索する方式：無関係なサービスや別の Desktop につながる危険があるため不採用。

## Constraints / Gotchas
- 8765 は他のツールでもよく使われる。TV アプリ内蔵のリレーサーバー（`UXTV_RELAY_PORT` / `UXTV_LIVE_PORT` の既定値 8765）は Desktop の LAN ポートとは無関係。
- 手入力 UI の既定ポート（`ux-sync-settings.ts`、`AppConstants.defaultServerPort`）は「最初に試す値」にすぎない。
