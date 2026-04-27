# Wails 未動作・未実装機能 探索レポート

Electron 版では動作していた（あるいは実装予定だった）が、Wails 版で死んでいる・または機能が不完全な箇所の調査結果です。

**更新（2026-04）:** 以下の項目は実装済み、または仕様として切り分け済みです。詳細は各節を参照してください。

## 1. プレイリスト追加機能（解消済み）

- `src/renderer/js/ui/list-renderer.js` のコンテキストメニューから `AddSongsToPlaylist` を呼び出すよう修正済み。
- アルバムグリッドの `AddSongsToPlaylist` 誤用は `AddAlbumToPlaylist` に修正済み（`src/renderer/js/ui/grid-renderer.js` / `bridge.js`）。

## 2. YouTube プレイリストのインポート機能（解消済み）

- Go 側 `ImportYouTubePlaylist` と `internal/youtube` のプレイリスト取得を追加。
- `src/renderer/js/core/init-listeners.js` から `youtubeAPI.importYouTubePlaylist` を呼び出し。進捗は `playlist-import-progress` / `playlist-import-finished` イベントを使用。

## 3. Direct Link (Audio Graph) — Wails 版では仕様上非対応

`src/renderer/js/features/audio-graph.js` において、Electron 専用の `ux-direct-link` ソケットは Wails では無効のままです。**Wails ビルドでは Direct Link を提供しない**方針とします。別途ネイティブ補助プロセスや OS ループバック連携が必要になるため、将来の別エピックで検討します。

## 4. ネイティブコンテキストメニュー（部分解消）

- OS ネイティブメニューへの復帰は行わず、HTML `showContextMenu` を継続。
- 曲リストの「プレイリストに追加」は §1 のとおり接続済み。

## 5. Discord RPC（解消済み）

- `server/discord_presence.go` と `app_audio.go` / `app.go` の再生ライフサイクルから `discord.Instance` を更新。
- 設定 `discordRichPresence` を `false` / `"false"` にすると無効化（未設定時は有効）。

## 6. 音量コントロール BaseGain × MasterVolume（解消済み）

- `pkg/audio` に正規化ゲイン（`SetNormalisationGain`）を追加し、`AudioSetNormalisationGain` から制御。
- `src/renderer/js/features/player.js` の Wails 分岐でラウドネス由来ゲインを Go 側に渡し、スライダー音量は従来どおり `AudioSetVolume` で適用（実効値は volume × normalisationGain）。

## まとめ

- 当初の主要デッドポイント（プレイリスト追加、Discord RPC、BaseGain、YouTube プレイリスト、メタデータ編集・クイズ永続化など）はバックエンド／フロントの配線で埋めています。
- **Direct Link だけは Wails では意図的に非対応**とし、コード上もフォールバック出力のままにします。
