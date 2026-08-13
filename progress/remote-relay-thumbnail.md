# 中継Now Playingサムネイルを可能な限り高解像度で転送する

## Decision
- 方針「サムネをできる限り綺麗に転送する」（動画そのものをTVへ出す試みは
  行わない）に基づき、`/v1/remote/state`の`relay.thumbnail`を可能な限り
  高解像度なYouTubeサムネイルURLにする。
- 採用したのは「Go側が一度だけプローブしてキャッシュする」方式（タスク
  指示にあった2択のうち後者）。理由: `/v1/remote/state`の`relay.thumbnail`
  を単一の「そのまま使えるURL」として維持でき、TV/iPhoneクライアント側に
  フォールバックロジックを実装させずに済む。プローブはHTTP HEADで音声パス
  外・曲ごとに高々1回（動画IDでキャッシュ）なので低コスト。
- レンダラー側（`src/renderer/js/features/youtube-thumbnail.ts`,
  `resolveRelayThumbnailCandidate`）は、動画IDが分かる場合は常に
  `maxresdefault`候補URL（`https://i.ytimg.com/vi/{id}/maxresdefault.jpg`）
  を構築して`NotifyYouTubePlaybackState`へ渡す。動画IDが取れない場合のみ
  従来通り`song.artwork`（文字列 or `{thumbnail,full}`）にフォールバック。
- Go側（`server/app_remote_relay_thumbnail.go`,
  `resolveRelayThumbnailURL`）は、受け取ったURLが
  `https://i.ytimg.com/vi/{id}/*.jpg`のパターンに一致する場合のみ、
  `maxresdefault → sddefault → hqdefault`の順にHEADプローブし、最初に
  200を返したものを採用する（全滅時は`hqdefault`を無条件フォールバックと
  して使う — YouTubeはほぼ全動画でこれを配信するため）。パターンに一致しな
  い（＝YouTube以外の）URLはそのまま素通りし、`NotifyYouTubePlaybackState`
  から無条件に呼び出しても安全にした。
- 解決結果は動画IDをキーに`sync.Map`でプロセス内キャッシュし、同じ動画の
  再生（リプレイ・タップ再確立など）で毎回ネットワークプローブしないように
  した。

## Alternatives considered
- クライアント（TV/iPhone）側でフォールバックチェーンを実行する案: 却下。
  `relay.thumbnail`を単一URLとして扱える現行契約を壊さずに済むGo側プローブ
  を優先した。将来的にクライアント数が増えても変更不要という利点もある。
- 動画の実解像度をYouTube Data APIやoEmbedで事前取得する案: 却下。追加の
  外部API依存・レート制限・APIキー管理が発生する。HEADプローブは
  `i.ytimg.com`への単純なリクエストのみで完結し、既存のffmpeg/Core Audio
  依存以外の新規外部連携を増やさずに済む。

## Constraints / Gotchas
- `maxresdefault.jpg`は動画によっては存在せず404になる（特に古い動画・
  ショート動画）。`sddefault`/`hqdefault`へのフォールバックはこのため必須。
- プローブ関数はテストで差し替え可能な変数
  （`probeYouTubeThumbnailAvailable`）にしてあり、実ネットワークアクセス
  無しに選択ロジック（`resolveBestYouTubeThumbnail`）とURL解決
  （`resolveRelayThumbnailURL`、キャッシュ挙動含む）をユニットテストして
  いる（`server/app_remote_relay_thumbnail_test.go`）。
