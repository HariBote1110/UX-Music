# Wails 未動作・未実装機能 探索レポート

Electron 版では動作していた（あるいは実装予定だった）が、Wails 版で死んでいる・または機能が不完全な箇所の調査結果です。

## 1. プレイリスト追加機能の未実装
`src/renderer/js/ui/list-renderer.js`
- 曲リストの右クリックコンテキストメニューにて、「プレイリストに追加」を選択した際の処理が TODO になっています。
```javascript
// TODO: プレイリストに曲を追加する処理
console.log(`Adding songs to playlist: ${playlist.name}`, songsForMenu);
```

## 2. YouTube プレイリストのインポート機能
`src/renderer/js/core/init-listeners.js`
- 「YouTubeプレイリストのリンク」追加ボタン（`#add-youtube-playlist-btn`）はありますが、Wails 環境では警告が出るだけで機能が実装されていません。
```javascript
onOk: (url) => console.warn('[YouTube] import-youtube-playlist is not implemented on Wails:', url)
```

## 3. Direct Link (Audio Graph) の環境依存制限
`src/renderer/js/features/audio-graph.js`
- Electron環境専用の `ux-direct-link` のソケット通信部分は Wails 環境では使用できず、強制的に無効化され通常出力にフォールバックします。
```javascript
console.log('[DirectLink] Direct Link is not available in Wails environment.');
isDirectLinkEnabled = false;
```

## 4. ネイティブコンテキストメニューの制限
`src/renderer/js/core/init-listeners.js`
- Electron の `ipcRenderer.invoke('show-context-menu')` を使ったネイティブOSのコンテキストメニューは実装されておらず、HTML ベースのメニュー（`showContextMenu`）で代替されていますが、一部操作（プレイリスト追加など）が未移植です。

## 5. Discord RPC のバックエンド連携漏れ
`internal/discord/discord.go`
- Go 側に DiscordRPC 構造体（Rich Presence 用）は移植・実装されていますが、`server/` 配下のオーディオバックエンド（`app_audio.go` や `player.go` などの再生イベント）から全く呼び出されていません。実質的に Wails 版では Discord RPC は動作していません。

## 6. 音量コントロール（BaseGainとMasterVolume統合）の未実装部分
`src/renderer/js/features/player.js`
- Wails への切り替え処理分岐内で `// TODO: BaseGainとMasterVolumeを統合` とあり、Web Audio 上で細かい Volume 制御を行う部分が Wails バックエンド処理へ完全には統合されていません。

## まとめ
- UI 要素としては存在していますが、裏側の Wails (Go) バックエンドの呼び出しと結合されていない、または意図的にフォールバック・無効化されている機能が散見されます。特に **Discord RPC のワイヤリング漏れ** と **コンテキストメニューの代替による「プレイリスト追加」機能のロスト** が主要なデッドポイントと言えます。
