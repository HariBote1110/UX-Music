# リモート再生のembed（YouTube公式再生）対応

## 背景

TVがYouTube由来の曲を`play-song`でPCへ再生指示する設計は「PC側はYouTube公式
埋め込み(embed)を起動しLAN中継する」前提だったが、ライブラリ上のYouTube由来
曲の大半はダウンロード済み（ローカルファイルを持つ）で、デスクトップは
ローカルファイルとして再生してしまい、embedもLAN中継も発生せずTVは無音に
なっていた。曲がYouTube出自かどうかとローカル音声ファイルを持つかどうかは
別の軸であり、クライアント側はどちらの経路を辿るか事前に知る必要がある、
というのが今回の設計是正の出発点。

## Decision（判別方法）

- ライブラリ曲の`type`フィールドが判別子。`server/app_youtube.go`の
  `buildStreamingSong`が`type:"youtube"`で登録する曲は`path`に動画URLしか
  持たず、ローカルファイルが存在しない（embed/中継専用）。それ以外
  （`type:"local"`、または`type`未設定の従来データ）は`path`が実ファイルパス。
  レンダラー側（`src/renderer/js/features/player.ts`の`play()`）も同じ
  `song.type === 'youtube'`判定でembed経路とローカル再生経路を分けている
  ため、この判定を`server.songHasLocalAudio`としてGo側に移植し一致させた。
- `GET /v1/remote/songs`の各曲へ`hasLocalAudio: boolean`を追加的フィールド
  として公開（既存フィールドは変更なし）。TV/モバイル側はこれを見て
  「PCへplay-songを投げてよいか」「LAN中継を待つべきか」を判断できる。
- `GET /v1/remote/file/{id}`は、`hasLocalAudio=false`な曲を要求されると
  従来の「動画URLをファイルパスとしてstatし403 Forbidden」という分かり
  にくい失敗ではなく、`no_local_audio`エラーコード付きの明確な404を返す。

## Decision（embed中の transport コマンド委譲）

`POST /v1/remote/command`のtoggle/play/pause/stop/seekは、これまでGoの
`audio.Player`を直接叩いていたが、embed再生中はGoのPlayerではなく
レンダラー内のYouTube IFrameプレイヤーが実際に鳴っている音を制御して
いるため、コマンドが届かなかった。

- Go側は`remoteRelay`（`server/app_remote_relay.go`）の`active`フラグを
  そのままembedセッションの活性判定に流用した（`embedSessionActive()`）。
  このフラグは`NotifyYouTubePlaybackState`がembed再生の開始/終了で更新
  しており、専用の新しいフラグを追加で持つ必要がなかった。
- `embedSessionActive()==true`のとき、toggle/play/pause/stop/seekは
  Go Playerを触らず`remote-embed-command`イベント（`{action, value}`）を
  レンダラーへemitする。`false`のとき（従来通り）はGo Playerを直接操作
  する挙動を一切変更していない。
- レンダラー側（`src/renderer/js/features/playback-manager.ts`の
  `handleRemoteEmbedCommandEvent`）は`player.ts`の
  `playCurrent`/`pauseCurrent`/`seek`/`stop`をそのまま呼ぶだけでよい。
  これらの関数はすでに`isEmbedPlayerActive()`を見てembed/ローカルを
  自動判別する実装になっており、embed専用の分岐を新たに書く必要は
  なかった。

## Decision（next/prev）

next/prevは既存通り、`remote-command`（文字列のみ）イベントのまま変更
しなかった。理由: 曲送り/戻しの「キュー」という概念はGoではなくレンダラー
側（`playback-manager.ts`の`playNextSong`/`playPrevSong`、
`state.playbackQueue`）にのみ存在する。遷移先の曲を`playSong()`→
`play()`へ渡す時点で、embed曲でもローカル曲でも`play()`が正しい経路
（embed起動 or ローカル再生）へ自動的に再突入するため、embedかどうかで
Go側の分岐を増やす必要がなかった。「キュー概念が無ければnext/prevは
エラーを返す」という代替案は、実際にはキュー概念が存在したため採用して
いない。

## 実装時に見つけたバグ（このタスクの一部として修正）

`remote-command`（next/prev用）イベントは、Go側は以前から
`ls.app.emit("remote-command", cmd.Action)`でemitしていたが、レンダラー
側にはこれを購読するリスナーが一つも存在しなかった（`remote-play-song`
用のリスナーはあったが、next/prev用は未実装のまま放置されていた）。今回
`initRemoteCommandListener`として新設し、`handleRemoteCommandEvent`
経由で`playNextSong`/`playPrevSong`へ委譲するようにした。

## Constraints / Gotchas

- `songHasLocalAudio`とレンダラー`play()`の`song.type === 'youtube'`判定は
  同じ意味を表す別実装（Go/TS）であり、片方だけ変更すると齟齬が生まれる。
  `type`の意味を変える場合は両方を同時に見直すこと。
- `embedSessionActive()`は`remoteRelay.State()`をそのまま使っている。
  relayは「一度に1本のYouTube動画しか流れない」前提のシングルトンなので、
  複数embedセッションの同時制御は現状の設計では扱えない（元々の
  `remoteRelay`自体の制約であり、今回新規に導入した制約ではない）。
