# ダウンロード音質オプション（Desktop → iPhone）

## Decision

- 3択の `DownloadAudioQuality`（`Core/DownloadAudioQuality.swift`）を新設し、`AppModel` に
  `librarySortOrder` と同じ `UserDefaults` 往復パターンで永続化した。
  - `.original`（既定・従来動作）: フル音質のみ。
  - `.aac`: AAC-LC 128kbps のみ（デスクトップの `GET /v1/remote/file?id=…`、`source=original` なし）。
  - `.both`: 両方。再生はフル音質を優先し、Watch 転送には AAC を使う。
- ダウンロード手順の導出（1リクエストか2リクエストか）は純粋関数 `DownloadRequestPlan.steps(for:)`
  に切り出し、`AppModel.downloadSong` はそれを順に実行するだけにした。`.both` は
  `downloadProgress[song.id]` を 0–0.5 / 0.5–1.0 に分割して単一の進捗値として見せる。
- ストレージ配置は**ステートレスな2ファイル構成**にした: オリジナルは従来どおり
  `DownloadedTracks/<stem>.<ext>`、AAC バリアントは同じディレクトリに `<stem>_aac.m4a` として
  並置する。理由: 設定を後から変更しても既存ファイルの組み合わせが常に有効であり続ける（オリジナル
  のみ／AAC のみ／両方、どの状態でも矛盾なく解決できる）。
  - `DownloadManager.resolvedExistingFileURL`（オリジナル解決）は `base == stem` の完全一致でしか
    マッチしないため、`<stem>_aac.m4a` はそこから見えない。これを意図的に維持し、
    `localAACVariantURLIfPresent`/`aacVariantDestinationURL` という別 API で扱う。
  - `loadMeta` 内の `trackListContainsStem` は `base == stem` に加えて `base == "\(stem)_aac"` も
    許容するよう拡張した。AAC のみダウンロードされた曲が再起動後の `loadMeta` で消えないようにする
    ため（オリジナルの `stem.*` が存在しないと従来ロジックではメタデータごと捨てられていた）。
- `isDownloaded` はオリジナル or AAC バリアントのどちらかが存在すれば true。`localPathString`
  はオリジナル優先、なければ AAC、なければ従来の（存在しない）レガシーパスにフォールバック
  （再生は常にフル音質優先）。

## サーバのffmpeg未使用フォールバックへの対応

デスクトップの `GET /v1/remote/file`（`source=original` なし）は本来 AAC-LC 128kbps m4a を返すが、
`server/app_remote.go` の `getOrTranscode` は ffmpeg が使えない環境ではオリジナルのバイト列に
フォールバックする。つまり「AAC として要求した」ダウンロードの中身が実は flac/mp3 等の場合がある。

これを `AACVariantFinalisePlan.plan(sniffedExtension:originalAlreadyPresent:)` という純粋関数で
判定table化した:

- sniff結果が `m4a` → 本物のAACなので `<stem>_aac.m4a` として保存（`storeAsVariant`）。
- `m4a` 以外 かつ オリジナルファイル未保存 → フォールバックで返ってきたオリジナルとして
  `<stem>.<ext>` に保存（`storeAsOriginal`、`finalizeDownloadedPart` と同じ経路）。
- `m4a` 以外 かつ オリジナルが既にある → 二重保存を避けて破棄（`discard`）。

`DownloadManager.finalizeDownloadedAACPart(at:song:)` がこの判定を実行する（sniff自体は既存の
`DownloadedTrackFormatSniffer.preferredExtension` を再利用）。

## Watch 転送での優先順位

`WatchTransferBridge.performTransfer` は `DownloadManager.watchTransferSourceURL(songId:)`
（AACバリアントがあればそれ、なければ解決済みオリジナル、どちらもなければ `nil`）を使うよう変更した。
AACバリアントは既に128kbps m4aなので `WatchTransferAudioPolicy.decision` が自然に `.passthrough`
を返し、オンデバイスの `WatchAudioTranscoder`（`watch-transfer-transcode.md`）は完全にスキップされる。
オリジナルのみダウンロードした曲は従来どおりトランスコード判定が働く。

## 遡及適用しない

設定変更は新規ダウンロードの挙動のみを変える。既存のダウンロード済みファイルは一切変更しない
（Settings 画面のフッターにその旨を明記）。

## AACビットレート選択（2026-08 追加）

- サーバ `GET /v1/remote/file?id=…` に `bitrate` クエリパラメータ（128/192/256/320）を追加した。
  `source=original` 指定時は無視される。未指定・不正値（範囲外の数値、非数値）は従来どおり
  128kbps にフォールバックする（Watch 向けデフォルト・旧クライアント互換のため）。不正値は
  サーバログに1行出力するが、エラーにはしない。
  - 純粋ロジックは `normaliseAACBitrateKbps` / `parseAACBitrateQueryParam`
    （`server/app_remote.go`）に切り出し、ffmpeg 実行なしでテスト可能にした。
  - キャッシュファイル名は `<sha256(songID)>_<bitrate>.m4a` に変更（`remoteTranscodeCacheStem`）。
    ロックキー（`transcodeOnce`）も `songID|bitrate` に変更し、異なるビットレートの同時リクエストが
    互いをブロックしないようにした。
  - **後方互換**: 128kbps のみ、旧形式キャッシュ `<sha256(songID)>.m4a`
    （`remoteLegacyTranscodeCacheStem`）が存在すればそれを再トランスコードせず再利用する。
    新規書き込みは常にビットレート付きファイル名を使う。
- iOS側: `Core/DownloadAudioQuality.swift` に `DownloadAACBitrate`（128/192/256/320、既定 256）を
  追加。`AppModel.downloadAACBitrate` に `downloadAudioQuality` と同じ `UserDefaults` パターンで
  永続化（キー: `uxmusic.download.aacBitrate`、不正な永続値は256にフォールバック）。
  `RemoteAPIClient.downloadFile` はこの値を `bitrate=` クエリとして付与する
  （`preferOriginalAudio == true` のときは付与しない）。クエリ組み立ては
  `RemoteAPIClient.downloadFileQueryItems` という純粋関数に切り出してユニットテストした。
  Settings 画面に「AAC Bitrate」ピッカー（menuスタイル）を追加し、ダウンロード音質が `.original`
  のときは無効化。フッターに「Watch転送は常に128kbpsへ最適化される」旨を明記。
- Watch転送は無変更: `WatchTransferAudioPolicy` は既に ≤192kbps の m4a をパススルー、
  それを超えるものはオンデバイスで128kbpsへ再トランスコードするため、256/320kbpsでダウンロード
  した曲も Watch では自動的に128kbpsになる（境界値192kbps/256kbps/320kbpsのテストを
  `WatchTransferAudioPolicyTests` に追加してこの相互作用を明文化した）。

## Alternatives considered

- 「AACのみ保持しオリジナルを消す／逆」のような単一ファイル切り替え方式は、設定変更のたびに
  既存ファイルを移動・削除する必要があり、途中失敗時の不整合リスクが高いため採らなかった。
  2ファイル併存＋ステートレス解決の方が実装・検証ともに単純。

## Constraints / Gotchas

- `finalizeDownloadedAACPart` は「discard」時、ダウンロード自体は成功しているのに永続化される
  ファイルが増えないケースがある（オリジナルが既にある状態で `.both` の2ステップ目が
  サーバフォールバックでオリジナルバイトを返した場合）。この場合ユーザーには実害はない
  （オリジナルは既にある）ため、`AppModel.downloadSong` はこれをエラー扱いしない
  （HTTPは成功しているため）。
- `AppModel.downloadSong` の `.both` で2ステップ目（AAC）が失敗した場合は `downloadError` に
  表示するが、1ステップ目で保存済みのオリジナルの登録は取り消さない。
