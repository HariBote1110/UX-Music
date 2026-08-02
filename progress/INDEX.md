# Progress Index

- [mobile-remote-control-footer.md](mobile-remote-control-footer.md) — UX Music Mobile: Remote Control タブのトランスポート行がミニプレイヤー＋タブバーのフッターに重なるバグの原因（`.ignoresSafeArea()` を持つ背景をZStackの兄弟にするとレイアウトサイズが背景に引きずられる）と修正
- [mobile-library-ui.md](mobile-library-ui.md) — UX Music Mobile: Local/Remote ライブラリ画面のタブ位置固定（共通 `LibrarySegmentedHeader`）と、行・グリッド・空状態の見た目統一（ellipsis メニュー集約、`ContentUnavailableView` は List 外に配置）
- [mobile-nowplaying-visuals.md](mobile-nowplaying-visuals.md) — UX Music Mobile: 再生画面スワイプ時のセーフエリア帯グラデーション侵食バグ修正（`nowPlayingSidePanelCoverage` による黒被覆レイヤー）と、歌詞画面（`NowPlayingLyricsScreen`）の Apple Music 風環境光デザイン刷新（背景共有・エッジフェード・タップシーク・自動スクロール一時停止）
- [mobile-sync-failover.md](mobile-sync-failover.md) — UX Music Mobile: mDNS 発見ピア選択時の疎通確認欠如による同期不安定バグの修正（WearConnectionResolver・ServerConfig.fallbackHosts・AppModel.withFailover）、および第2の根本原因である wearAuthMiddleware 認証トークン欠落（401）の修正（ServerConfig.token・WearAPIClient の X-UX-Music-Token・checkAuthorised）
