# TVの1秒未満再生開始: /v1/remote/file/{id}?stream=aac ライブトランスコード配信

## Decision
- `GET /v1/remote/file/{id}?stream=aac` を新設。ローカルキャッシュを持たない
  TVクライアントが、フルダウンロード完了を待たずに再生開始できるようにする
  ための機能。実装は `getOrTranscode`（キャッシュm4a生成）とは別経路の
  `serveFileStreamAAC`（`server/app_remote_stream.go`）で、ffmpegの標準出力
  をそのままHTTPレスポンスへパイプする。キャッシュもファイル書き出しもせず、
  最初のADTSフレームが生成され次第クライアントへ届く。
- 出力フォーマットは `/v1/remote/relay` と完全に同一（ADTS AAC-LC
  256kbps・44.1kHz・ステレオ、`relayAACBitrateKbps`定数を共有）。TV側は
  relay用に実装済みのADTSデコードパイプラインをそのまま再利用できる。
- クライアント切断時は `r.Context()` のキャンセルが `exec.CommandContext`
  経由でffmpegプロセスを確実に停止・reapする（`cmd.Wait()`で回収、ゾンビ化
  させない）。
- `?stream=aac` 指定時は常にチャンク転送（`Content-Length`なし）になるため
  Rangeリクエストは意味を持たず、素通り（無視）する仕様としてハンドラの
  コメントで明記した。プレーンな `GET /v1/remote/file/{id}`（`?stream=`なし）
  は既存動作のまま完全に不変。
- `no_local_audio` 404判定（embed専用曲）は `?stream=aac` 分岐より前に既存
  ロジックのまま実行されるため、そのままエラーコードが伝播する。

## Alternatives considered
- 常時ストリーミングへ一本化（`getOrTranscode`のキャッシュ経路を廃止）:
  却下。キャッシュ経路は複数クライアント・複数回再生で再エンコードを避ける
  価値があり、既存クライアント（Watch含む）の挙動を変えたくない。ストリーム
  はTVの「初回・キャッシュなし」ケース専用の追加選択肢とした。
- `/v1/remote/relay`（ブロードキャスト型・単一ソース）を流用し曲を都度差し
  替える案: 却下。relayは「今まさにPC上で鳴っている音」の中継が前提で、
  song単位のオンデマンド要求とはライフサイクルが異なる（複数クライアントが
  同時に別々の曲をストリームする可能性がある）。ファイル単位で独立した
  ffmpegプロセスを都度起動する現行方式の方がシンプルで安全。

## Constraints / Gotchas
- `-flush_packets 1` を付けないとffmpegが内部avioバッファにADTSフレームを
  溜め込み、プロセス終了までstdoutへ出力しない — `remote-relay.md`で発見済
  みの落とし穴と同一。ライブストリーミングでは必須。
- テストでは実ffmpegバイナリで `-f lavfi -i sine=...` により長尺WAVを都度
  生成し、初回バイト到達までの時間（≈数百ms〜)と切断時のプロセスreapを
  実測で検証している（`server/app_remote_stream_test.go`）。ffmpeg不在環境
  では既存パターン通り `t.Skip`。
