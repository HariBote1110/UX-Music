> **このドキュメントは廃止済みです（2026-08-11）。**
> 旧 `/sync/*`（無版）プロトコルの実装計画です。LAN API v1 統一（`progress/lan-api-v1.md`）により `/v1/pairing/*` へ再編済みです。

# UX Sync 手動ペアリング導線 実装計画

## 背景・目的

mDNS が使えない／不安定なネットワーク（マルチキャスト遮断、AP isolation、有線↔無線跨ぎ等）は珍しくない。現状の UX Sync は**発見リストからしかペアリングを開始できず**、mDNS が動かないと相手を選べない。直接到達（HTTP / `/sync/identity` / `/sync/pairing/*`）自体は機能するため、**IP / ホストを手入力してペアリングを開始できる保険導線**を追加する。

バックエンドの `StartSyncPairing(baseURL)` は任意 URL を受け取れるので、本対応は主に renderer の追加で済む（バックエンド変更なし）。

## スコープ

- UX Sync 専用設定「端末」タブに**手動ペアリング入力**を追加（IP/ホスト＋任意ポート＋「接続」）。
- 入力から baseURL を組み立て、**既存のペアリングフロー**（`startSyncPairing` → 6桁コード表示 → `confirmSyncPairing`）に流す。
- 成功後は既存どおりトークン＋既知ピアとして保存され、端末一覧に反映。

対象外: バックエンドのペアリング仕様変更、mDNS 自体の改善（別途修正済み/進行中）。

## 設計

### 純ロジック（テスト容易な関数として切り出す）

`manualSyncPeerBaseUrl(host: string, port?: string): string | null`
- trim する。空なら `null`。
- 既に `http://` / `https://` で始まる完全 URL ならそのまま（末尾スラッシュ除去）採用。
- それ以外は `http://<host>:<port>` を組む。`port` 未指定・空なら既定 `8765`。
- `host` に `host:port` 形式が貼られた場合はそれを尊重（port 欄は無視）。
- IPv6 リテラルは `[...]` で囲う（任意・できれば対応）。
- 不正（host が空、制御文字混入等）は `null`。

### UI（init-settings.ts / ux-sync-settings.ts）

- 「端末」タブの探索ボタン付近に行を追加: テキスト入力（IP またはホスト名）、ポート入力（任意・placeholder `8765`）、ボタン「接続」。
- 「接続」押下時:
  1. `manualSyncPeerBaseUrl(host, port)` で baseURL を得る。`null` ならエラー表示。
  2. baseURL から**合成 SyncPeer**（例 `{ displayName: 手動入力値, hosts: [host], reachableBaseUrl: baseURL, roles: [], paired: false }`）を作り、既存の `renderUxSyncPairingStart`（または同じ `startSyncPairing`→コード→`confirmSyncPairing` 経路）を呼ぶ。
  3. 以降は発見ピアと同一フロー（6桁コード表示→確定→保存）。
- 成功後は端末一覧／同期元セレクトを再描画（`ListSyncDevices` 由来の既知ピアに乗る）。
- `syncPeerPairingBaseUrl` が合成ピアの `reachableBaseUrl` をそのまま返すことを確認（必要なら合成ピアの形を合わせる）。

## テスト（TDD・Red 先行）

1. `manualSyncPeerBaseUrl('192.168.0.143')` → `http://192.168.0.143:8765`。
2. `manualSyncPeerBaseUrl('192.168.0.143', '9000')` → `http://192.168.0.143:9000`。
3. `manualSyncPeerBaseUrl('192.168.0.143:8765')` → `http://192.168.0.143:8765`（port 欄無視）。
4. `manualSyncPeerBaseUrl('http://host:8765/')` → `http://host:8765`（完全 URL 尊重・末尾スラッシュ除去）。
5. `manualSyncPeerBaseUrl('')` / 空白のみ → `null`。
6. UI: 「接続」押下で `startSyncPairing` が組み立てた baseURL で呼ばれる（モック）。空入力ではエラー表示で呼ばれない。

## バージョン

新機能追加のため `PhaseVer` を +1、`SubVer` を `a` にリセット。

## ドキュメント更新

`markdown/Task.md`、`markdown/requirement.md`、`markdown/features.md`、`markdown/ux-music-sync-plan.md` に手動ペアリング導線を追記。
