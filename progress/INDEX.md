# Progress Index

- [watch-integration.md](watch-integration.md) — UX Music Mobile: Apple Watch 再生機能の移植（フェーズ2〜5）。共有 `WatchTransferMeta`/`WatchLibraryIndex`（iOS/watchOS 両ターゲット）、iOS 送信ブリッジ（ダウンロード済みのみ転送可）、watchOS 受信・永続化・AVPlayer 再生・UI。フェーズ5でLibrary⇄Now Playingの水平ページング化・Digital Crownシーク・MPNowPlayingInfoCenter/MPRemoteCommandCenter連携を追加
- [mobile-device-identity-zero-uuid.md](mobile-device-identity-zero-uuid.md) — UX Music Mobile: `DeviceIdentity` がシミュレータ等で返るゼロUUIDを有効な識別子として誤採用し、デスクトップ側 `deviceAuthTokens` に衝突登録される不具合の修正（`resolvedDeviceId` への切り出しとフォールバック生成）
- [mobile-lan-api-v1-migration.md](mobile-lan-api-v1-migration.md) — UX-Music-Mobile を新 LAN API v1 に追従: wear 命名の全廃（RemoteAPIClient 等への改名）、Bearer 認証、secret→redeem 方式のペアリングへの変更
- [lan-api-v1.md](lan-api-v1.md) — LAN API v1 統一プロトコル仕様: `/wear/*`・`/sync/*` を `/v1/remote/*`・`/v1/sync/*` に再編、デバイス別トークン認証（`deviceAuthTokens`）・Bearer 一本化・QR→redeem 発行ペアリング・JSON エラー形式・バージョニング1体系化の決定記録
- [mobile-remote-control-footer.md](mobile-remote-control-footer.md) — UX Music Mobile: Remote Control タブのトランスポート行がミニプレイヤー＋タブバーのフッターに重なるバグの原因（`.ignoresSafeArea()` を持つ背景をZStackの兄弟にするとレイアウトサイズが背景に引きずられる）と修正
- [mobile-library-ui.md](mobile-library-ui.md) — UX Music Mobile: Local/Remote ライブラリ画面のタブ位置固定（共通 `LibrarySegmentedHeader`）と、行・グリッド・空状態の見た目統一（ellipsis メニュー集約、`ContentUnavailableView` は List 外に配置）
- [mobile-nowplaying-visuals.md](mobile-nowplaying-visuals.md) — UX Music Mobile: 再生画面スワイプ時のセーフエリア帯グラデーション侵食バグ修正（`nowPlayingSidePanelCoverage` による黒被覆レイヤー）と、歌詞画面（`NowPlayingLyricsScreen`）の Apple Music 風環境光デザイン刷新（背景共有・エッジフェード・タップシーク・自動スクロール一時停止）
- [mobile-sync-failover.md](mobile-sync-failover.md) — UX Music Mobile: mDNS 発見ピア選択時の疎通確認欠如による同期不安定バグの修正（WearConnectionResolver・ServerConfig.fallbackHosts・AppModel.withFailover）、および第2の根本原因である wearAuthMiddleware 認証トークン欠落（401）の修正（ServerConfig.token・WearAPIClient の X-UX-Music-Token・checkAuthorised）
