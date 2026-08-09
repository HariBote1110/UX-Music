# Watch転送前オンデバイスAAC128トランスコード

## Decision

- `watch_transfer_research/notes/watch-transfer-bottleneck.md` の調査結論（ライブラリの88%が
  FLAC、AAC128kbps化で転送バイト数を約7〜8x削減できる。WCSessionの実効帯域はアプリ側で
  制御不能なため、サイズ削減が唯一かつ最大の最適化）を受け、`WatchTransferBridge.performTransfer`
  にオンデバイストランスコードを組み込んだ。
- **送信判定**: `Core/WatchTransferAudioPolicy.swift`（`WatchTransferAudioPolicy.decision(fileType:fileSizeBytes:duration:)`、
  AVFoundation非依存の純関数）。
  - FLAC/WAV/AIFF/CAF/Ogg/Opus/WMA・不明拡張子は常に `.transcode`。Ogg/Opus/WMAは単に大きい
    だけでなく、watchOSの`AVPlayer`がそもそも再生できない形式なので、トランスコードは
    再生可否の問題でもある。
  - mp3/m4a/aac/mp4（Watchで既に再生可能かつ非可逆圧縮済み）は、推定ビットレート
    （`fileSizeBytes * 8 / duration`）が192kbpsを超える場合のみ `.transcode`、それ以下は
    `.passthrough`。durationが0以下（不明）の場合は再エンコードしない安全側にふって
    `.passthrough`。
  - 目標ビットレートは `WatchTransferAudioPolicy.targetBitRate`（128,000bps）で一元管理し、
    `WatchAudioTranscoder` 側もこの値を参照する。
- **トランスコード本体**: `Services/WatchAudioTranscoder.swift`（`WatchAudioTranscoder.transcodedFileURL(source:songId:)`、
  `async throws`）。`AVAssetReader`（LPCM 16bit出力）→ `AVAssetWriter`（AAC-LC 128kbps /
  44.1kHz / stereo、`.m4a`）のパイプラインで変換する。
  - キャッシュ先は `Caches/WatchTranscode/<stem>.m4a`（`<stem>` は既存の
    `WatchTransferMeta.storageStem(for:songId)` を再利用し、Watch側の保存ファイル名の
    導出方法と一貫させた）。キャッシュファイルの更新日時が元ファイル以上なら再エンコードせず
    そのまま返す。
  - 書き出しは `<stem>.m4a.tmp` に行い、完了後にリネームで原子的に配置する
    （デスクトップサーバ側 `server/app_remote.go` の `getOrTranscode` と同じ発想。
    部分ファイルを完了扱いにしない）。
- **`WatchTransferBridge` への組み込み**:
  - `WatchTransferQueueItem.Phase` に `.preparing`（変換中）を追加し、`SettingsScreen` の
    転送キュー表示に「変換中…」を出す。
  - `performTransfer` は元ファイルのサイズ・拡張子・`song.duration` から
    `WatchTransferAudioPolicy.decision` を呼び、`.passthrough` なら従来どおり即
    `transferFile`、`.transcode` ならまず `.preparing` にしてから `Task` 内で
    `WatchAudioTranscoder` を実行する。
  - トランスコード成功/失敗後に「実際どのファイル・fileTypeを送るか」の分岐は
    `WatchTransferTranscodeOutcome.fileToSend(originalURL:originalFileType:transcodedURL:)`
    という純関数に切り出した（`WatchTransferDownloadOutcome` と同じ設計方針）。成功時は
    キャッシュ済みm4aを`fileType: "m4a"`で、失敗時は元ファイル・元fileTypeにフォールバックする
    （**転送が遅くても届く方が、転送が届かないより良い**という原則）。
  - `transferFile` 呼び出し自体は `sendFile(_:fileType:song:)` に切り出し、passthrough経路と
    transcode経路の両方から共通利用する（アートワーク転送・キュー状態遷移は元の
    `performTransfer` と同一のまま）。

## Alternatives considered

- **サーバ側の変換済みバリアントをWatch用に別途ダウンロードする案**（デスクトップには既存の
  `server/app_remote.go` `getOrTranscode` があるが、iPhone側は現状 `source=original` 固定で
  未使用）は却下。デスクトップへの接続が転送の都度必須になり、`DownloadManager` が1曲につき
  「original用」「Watch用」の2変種を管理する複雑さが増える。オンデバイス変換なら
  ダウンロード済みの曲はオフラインでもいつでもWatchへ転送できる。
- ビットレート判定の閾値は128kbpsぴったりではなく192kbpsとした。128kbps前後のmp3/m4aを
  わずかに超えているだけで再エンコード（=品質劣化＋CPU時間）するのは割に合わないため、
  ある程度の余裕を持たせた。

## Constraints / Gotchas

- `WatchAudioTranscoder` は `WCSession`/`WatchTransferBridge` に依存しない独立した構造体
  （`FileManager` のみ注入可能）にしたため、`UX-Music-MobileTests/WatchAudioTranscoderTests.swift`
  から実際に`AVAssetReader`/`Writer`を走らせる統合寄りのテストが書けた
  （`AVAudioFile`でサイン波2秒WAVを生成→変換→サイズ・拡張子・再生長・キャッシュ再利用を検証）。
- `WatchTransferBridge` は `@MainActor` クラスだが、`performTransfer`内の`Task { }`は
  非detachedなのでMainActor isolationを引き継ぐ。ただし実際のエンコード処理（サンプル
  バッファのコピー・書き込み）は`AVAssetWriterInput.requestMediaDataWhenReady(on:)`が
  指定した専用`DispatchQueue`上のコールバックで行われるため、GCDレベルではメインスレッドを
  塞がない。
- 送信メタデータの`fileType`は実際に送るバイト列と一致させる必要がある
  （トランスコード成功時は`"m4a"`に上書き。元の`song.fileType`のまま送ると、Watch側が
  誤った拡張子でファイルを保存し再生に失敗する）。

## 参照

- `watch_transfer_research/notes/watch-transfer-bottleneck.md`（測定・方針決定の元調査）
- `progress/watch-integration.md`（Watch転送機能全体の経緯）
