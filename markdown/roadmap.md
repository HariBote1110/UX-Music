# ロードマップ (Roadmap)

## v0.1.0 (Beta) - [COMPLETED]
* 基本的な音楽再生機能
* ライブラリのスキャンと管理
* アルバムビュー、アーティストビュー
* プレイリスト機能
* YouTubeからのダウンロード機能
* Discord RPC 連携

## v0.2.0 (Beta 2) / 現在の進捗 - [ACTIVE]
* **UX Rip (CDリッピング)**: MusicBrainz連携による高機能な吸い出し。 [DONE]
* **UX MTP (Walkman転送)**: macOSからの楽曲転送基盤。 [DONE]
* **高度なイコライザー**: 10バンド・グラフィックEQ。 [DONE]
* **ムード解析**: フォーユー・プレイリストの動的生成。 [DONE]
* **UI/UXの改善**: Light Flightモード、仮想スクロールの強化。 [DONE]
* **パフォーマンス最適化**: Workerスレッドへの完全移行。 [DONE]

## 今後の展望 (Future Plans)
* **スマート検索**: キーワード、アーティスト、アルバムを跨ぐ高速検索機能。
* **タグエディタ**: ライブラリ上でのメタデータ直接編集機能。
* **歌詞の自動取得**: オンラインサービス(Musixmatch等)との連携。
* **クロスフェード再生**: 楽曲間の滑らかな遷移。
* **UX Sync**: 同一 LAN 上の端末間で、mDNS 自動発見、6桁コード確認ペアリング、再生履歴・お気に入り・プレイリスト同期、母艦 Mac mini から持ち運び用 MacBook Air への圧縮音源キャッシュ、再生移行を行う。Phase 1 としてペアリングと再生イベントプッシュ基盤、Phase 2 として mDNS 自動発見基盤、Phase 3 として設定画面の自動発見一覧 UI、Phase 4 として発見 peer からのペアリング UI、Phase 5 として UX Sync 専用設定画面、Phase 5.1 として Windows 側発見 fallback、Phase 5.2 として SSH 検証 CLI と親から子への音源pull MVP、Phase 5.3 として音源pull GUI、Phase 5.3.1 としてペア済み端末復元と同期操作修正、Phase 5.4 として音源push転送、Phase 5.5 としてプロトコルスキーマとバージョンネゴシエーション、Phase 5.6 として転送進捗表示と MP3 320kbps 転送、Phase 5.7 として再生回数イベントの自動同期、Phase 5.8 としてジャケットの自動補完同期、Phase 5.9 として空き容量安全停止、Phase 5.13 として再生回数収束、Phase 5.14 として統一ライブラリビュー、Phase 5.15 としてシームレスDL再生、Phase 5.16 としてスマートキャッシュと容量ポリシー、Phase 5.17 として pull 側ポータブル MP3 320kbps キャッシュを実装済み。その後 LAN API v1 として `/v1/remote/*`・`/v1/sync/*` へ再編済み（`/wear/*`・無版 `/sync/*` は廃止、詳細は [progress/lan-api-v1.md](../progress/lan-api-v1.md) を参照）。当時の実装計画は [archive/ux-music-sync-plan.md](./archive/ux-music-sync-plan.md) に保管（廃止済み）。
