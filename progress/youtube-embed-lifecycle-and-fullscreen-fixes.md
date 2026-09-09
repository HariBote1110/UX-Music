# YouTube埋め込みのライフサイクルとフルスクリーン周りのバグ修正

対象バージョン: 1.0.0-Beta-70a / ブランチ `fix/youtube-fullscreen-bugs`

## 決定

報告された4件の症状を調査した結果、独立した2つの真因に集約されると判断した。

### 真因A: 増分ライブラリ更新でのマイグレーション誤判定

`addSongsToLibrary` は「`albums` が空」かつ「`songs[0].artwork` がオブジェクトでない」ことを
根拠に旧形式マイグレーションを実行し、`groupLibraryByAlbum(true)` が `state.library` 全曲から
`artwork` を削除していた。YouTube曲追加時の `scan-complete` は追加した1曲だけを渡すため、
その曲の artwork が文字列URLであることをもって条件が常に成立していた。

判定を以下の3点で修正した。いずれか1つでも十分だが、多層防御として全て入れている。

- `load-library` の完全ロード時のみ判定する（`isFullLibraryLoad` フラグ）
- `songs[0]` ではなく配列全体を走査する
- `https:` / `data:` スキームの artwork は旧形式とみなさない

### 真因B: embedプレイヤーのライフサイクル境界の欠如

`destroyEmbedPlayer()` の呼び出し元が `mountEmbedPlayer()` と `player.ts` の `stop()` しか
なかった。ローカル曲の再生はGo側の `AudioPlay` が直接行うため、キュー経由（`QueueJump`）の
切替では `stop()` を通らず、`isEmbedPlayerActive()` が true のまま残っていた。これが
NowPlayingの固着とトランスポート操作の無効化（死んだiframeへの `postMessage`）、および
`video-mode` クラスの残留による16:9固着を同時に引き起こしていた。

`handleQueueStateChangedEvent` に `syncEmbedPlayerForTrack(currentSong)` を追加し、
**どの経路を通ったかではなく current track を基準に** embed を破棄する形へ変更した。

## 検討して棄却した代替案

- **バグ2b（フルスクリーン切替で再生位置が飛ぶ）を `currentTime` の退避・復元で回避する案**:
  棄却。iframeの再ペアレント自体をやめ、`document.body` 直下に一度だけ配置して
  表示先の矩形のみを `position: fixed` で追従させる方式にした。再読込が起きないため
  再生位置だけでなく再生の途切れも発生しない。

- **位置追従を `MutationObserver(document.documentElement, {subtree:true})` で行う案**:
  一度実装したが棄却。仮想スクロールのトラックリストや歌詞の毎フレーム描画のたびに
  `getBoundingClientRect()` による強制同期レイアウトが走り、`desktop-seek-playpause-freeze-fix`
  や Watch曲一覧で対処してきたフリーズ要因を再導入する。コンテナと `offsetParent` 連鎖への
  `ResizeObserver` に限定し、全トリガーをrAFへ合流させて1フレーム最大1回の測定に集約した。

- **フルスクリーンの閉じるボタンを `document.body` へ物理移動してz-indexを昇格する案**:
  一度実装したが棄却。他モジュールのマークアップに対する手術であり、ボタンが外れている
  間にオーバーレイが再構築されると不整合を起こす。

- **`.fs-overlay` の z-index を 9002 へ引き上げる案**: 棄却。オーバーレイは不透明な
  グラデーション背景を持つため、embed wrapper (9001) が背後に回りフルスクリーンの映像が
  一切表示されなくなる。閉じるボタン（右上）と映像枠（`.fs-left` 内）は矩形が重ならないため、
  そもそも昇格は不要だった。

- **オーバーレイ全体を `-webkit-app-region: drag` にする案**: 棄却。子要素のクリックを
  飲み込み、歌詞のテキスト選択も阻害する。上端32pxの専用帯 `.fs-drag-region` を設けた。

## 制約・注意点

- **「フルスクリーンモード」はOS/Wailsのウィンドウ全画面化ではない**。`main.go` に
  `WindowFullscreen` 系の呼び出しはなく、`document.body` に被せるCSSオーバーレイである。
  したがってウィンドウ移動用のドラッグ領域（`.title-bar`、高さ32px）は自前で再現する必要がある。

- **embed wrapper は `document.body` 直下の `position: fixed` 要素である**。今後
  `#now-playing-artwork-container` や `#fs-video-slot` の子孫セレクタで embed を
  スタイリングしようとしても効かない。同様に、これらのコンテナの `innerHTML` を直接
  クリアしてはならない（`resetEmbedArtworkContainer()` を使うこと）。

- **z-index の取り決め**: embed wrapper はサイドバー時 `1`、フルスクリーン時 `9001`。
  `.fs-overlay` は `9000`。これを崩すとフルスクリーンの映像が消えるか、embedが
  モーダル（1000番台）や通知（3000）やコンテキストメニュー（10000）を覆う。

- `save-migrated-data` チャンネルはGo側にもフロント側にもハンドラが存在しないデッドコード
  だったため送信を削除した。マイグレーション結果は元々永続化されていない。

- `internal/youtube/youtube.go` の `DownloadThumbnail` はどこからも呼ばれていない。
  YouTube曲のサムネイルは常にリモートURL参照であり、オフラインでは表示できない（未対応）。

- lint は `js/features/ux-sync-settings.ts:588` と `js/features/visualizer.test.ts:160` で
  失敗するが、今回の変更以前から存在する無関係なエラーである。

## 未検証

実機での再現確認は未了。特にバグ2b（フルスクリーン切替で再生が途切れないこと）は
WKWebView の実挙動に依存するため、実機での確認が必要。
