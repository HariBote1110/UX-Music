# LAN API v1 統一プロトコル仕様（/wear・/sync 統合）

## Decision

未リリースであることを利用し、互換レイヤーなしで LAN API を一括再設計する。

- **名前空間**: 端末（モバイル/Watch）向けは `/v1/remote/*`、デスクトップ間同期は `/v1/sync/*`。旧 `/wear/*`・`/sync/*`（無版）は廃止。「wear」という語はサーバー・クライアント双方のコード/設定キーから全廃する。
- **認証**: 全デバイス共通で**デバイス別トークン**。設定キーは `deviceAuthTokens`（`map[deviceID]token`）に統合し、`wearAuthToken`・`syncAuthTokens` は廃止。
  - 渡し方は `Authorization: Bearer <token>` に一本化。
  - 例外: `<img>`/AVPlayer 等ヘッダを付けられないメディア系 GET（file / artwork）のみ `?token=` クエリを許可。
- **ペアリング**: 統一エンドポイント `/v1/pairing/*`。
  - モバイル: QR (`uxmusic://pair?host=&port=&secret=`) → `POST /v1/pairing/redeem` で secret を提示しデバイス別トークンを発行。生トークンの QR 直配布はやめる。
  - デスクトップ間: 従来どおり `start`（6桁コード・2分TTL）→ `confirm` でトークン発行。
  - デバイス単位の失効・個別解除が可能になる。
- **公開（無認証）エンドポイントの規則**: 「identity と pairing のみ」。それ以外は全て認証必須。
  - `GET /v1/identity` — 旧 `/wear/ping` + `/sync/identity` を統合。`protocolVersion` / `schemaVersion` / hostname / roles を返す。
  - `/v1/pairing/*`
- **バージョニング**: `protocolVersion`（文字列）+ `schemaVersion`（日付）の1体系のみ。`wearApi`（int）は廃止。
- **エラー形式**: 全エンドポイントで `{"error": {"code": "...", "message": "..."}}` の JSON。`http.Error` のプレーンテキストは廃止。

## エンドポイント対応表

| 旧 | 新 |
|---|---|
| GET /wear/ping, POST /sync/identity | GET /v1/identity（公開） |
| GET /sync/schema | GET /v1/identity に統合 |
| GET /wear/mobile | 廃止（ドキュメントはリポジトリ側へ） |
| POST /sync/pairing/start・confirm | POST /v1/pairing/start・confirm（公開） |
| （新設） | POST /v1/pairing/redeem（公開・QR用） |
| GET /wear/songs | GET /v1/remote/songs |
| GET /wear/lyrics | GET /v1/remote/lyrics |
| GET /wear/playlists | GET /v1/remote/playlists |
| GET /wear/file[/{id}] | GET /v1/remote/file/{id}（?token= 許可） |
| GET /wear/artwork/[{id}] | GET /v1/remote/artwork/{id}（?token= 許可） |
| GET /wear/loudness | GET /v1/remote/loudness |
| GET /wear/state | GET /v1/remote/state |
| POST /wear/command | POST /v1/remote/command |
| /sync/library/*, /sync/assets/*, /sync/discover | /v1/sync/library/*, /v1/sync/assets/*, /v1/sync/discover |

## Alternatives considered

- `/v1/device/*`（提案時の推奨）→ ユーザー選定で `/v1/remote/*` に決定。リモート再生・配信のニュアンス重視。
- 全部 `/v1/sync/*` に統合 → 役割が名前で分からなくなるため不採用。
- 旧パスのエイリアス維持 → 未リリースのため不要と判断。

## Constraints / Gotchas

- ポートは 8765 のまま。mDNS `_uxmusic-sync._tcp` のアドバタイズも共通で1本。
- `wearAuthToken` は既存ユーザーの settings.json に残るが、未リリースのため移行処理は書かない（無視されるだけ）。
- Mobile 側は `WearAPIClient` → `RemoteAPIClient` 等へ改名・新パス追従が必要。`UX-Music-Wear/` サブプロジェクトは今後 Mobile へ統合予定のため追従させない（クライアントごと廃棄予定）。
- `lanAuthMiddleware` のパス prefix 分岐は廃止し、共通ミドルウェア（Bearer 検証 + メディア系のみ query 許可）に統合する。
