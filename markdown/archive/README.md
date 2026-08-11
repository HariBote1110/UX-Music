# アーカイブ済みドキュメント

このディレクトリには、廃止済みの設計/実装計画・仕様書を保管しています。各ファイル冒頭に廃止理由と現行の参照先を明記したバナーがあります。

| ファイル | 廃止理由 |
| :--- | :--- |
| [ux-music-sync-plan.md](./ux-music-sync-plan.md) | 旧 `/sync/*`（無版）プロトコルの実装計画。LAN API v1 統一（`/v1/remote/*`・`/v1/sync/*`）で置き換え済み |
| [ux-music-sync-protocol.md](./ux-music-sync-protocol.md) | 旧 `/sync/*`・`/wear/*` の wire schema。LAN API v1 統一で置き換え済み |
| [Task.md](./Task.md) | UX Sync（旧API）の完了済みタスク履歴。記載のエンドポイント・設定キーは現行実装と一致しない |
| [requirement.md](./requirement.md) | Electron 版アーキテクチャと旧 `/wear/*`・`/sync/*` API を前提にした機能仕様書（v0.1.9-Beta-37c 時点） |
| [document.md](./document.md) | Electron 版のディレクトリ構成（`src/main/` 等）を前提にした技術仕様書。現行は Wails（Go + TypeScript）版 |
| [sync-manual-pairing-plan.md](./sync-manual-pairing-plan.md) | 旧 `/sync/*` 手動ペアリング導線の実装計画。`/v1/pairing/*` へ再編済み |
| [sync-playcount-metadata-plan.md](./sync-playcount-metadata-plan.md) | 旧 `/sync/*` 再生回数メタデータ同期の実装計画。`/v1/sync/*` へ再編済み |
| [sync-portable-mp3-plan.md](./sync-portable-mp3-plan.md) | 旧 `/sync/*` ポータブル mp3 キャッシュ（Phase 5）の実装計画。`/v1/sync/*` へ再編済み |
| [sync-realworld-bugfixes-plan.md](./sync-realworld-bugfixes-plan.md) | 旧 `/sync/*` 実機検証バグ修正計画。`/v1/sync/*` へ再編済み |
| [sync-streaming-cache-plan.md](./sync-streaming-cache-plan.md) | 旧 `/sync/*` シームレスDL再生・スマートキャッシュ（Phase 3+4）の実装計画。`/v1/sync/*` へ再編済み |
| [sync-unified-library-plan.md](./sync-unified-library-plan.md) | 旧 `/sync/*` 統一ライブラリビュー（Phase 2）の実装計画。`/v1/sync/*` へ再編済み |
| [sync-playcount-convergence-plan.md](./sync-playcount-convergence-plan.md) | 旧 `/sync/*` 再生回数収束の実装計画。`/v1/sync/*` へ再編済み |

現行の LAN API 仕様は [`progress/lan-api-v1.md`](../../progress/lan-api-v1.md)（決定記録）、機能一覧は [`markdown/features.md`](../features.md) を参照してください。
