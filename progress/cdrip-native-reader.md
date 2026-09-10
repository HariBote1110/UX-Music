# CD リッピング純 Go コアと OS seam

## Decision

cdparanoia の実行ファイルと libcdio dylib を同梱して呼び出す方式を段階的に置き換えるため、リッピング判定・再読・オフセット補正・PCM WAV 出力を `pkg/cdrip` の OS 非依存 Go コアとして実装する。ドライブへアクセスする部分は `DiscReader` に限定し、Ripper は `UX_MUSIC_CDRIP_NATIVE=1` のときだけ macOS reader factory を使う。factory が無効、または open に失敗した場合は cdparanoia 経路へ戻る。

## macOS native reader

`pkg/cdrip/disc_reader_darwin.go` は IOKit の `IOCDMedia` service を列挙し、`kIOBSDNameKey` から `/dev/r<bsdname>` を組み立てて read-only で開く。複数台は IOKit の列挙順で先頭を使用し、`DiscoverNativeDiscDevices` で全リストを取得できる。媒体がない場合は `ErrNoAudioCD`（`no audio CD present: ...`）を返す。

TOC は SDK の `DKIOCCDREADTOC`、`kCDTOCFormatTOC`、`CDTOC` レイアウトを C 層で受け、解析は共通 Go の `parseCDTOC` が担当する。track 1..99 と lead-out (`0xA2`) を MSF から LBA に変換し、control bit `0x04` の data track を UI の audio track から除外する。Enhanced CD の別セッションに data track が続く場合は、直前の audio track の終端を次セッション開始の 11400 sectors 前に補正する。raw read は `DKIOCCDREAD` に user area/CDDA を指定し、2352 bytes/sector を厳密に返す。

## 比較 CLI

実機で次のように比較する。`out-native.wav` の SHA-256 は WAV header を除く PCM payload のハッシュである。

```sh
go build ./cmd/cdrip-compare
./cdrip-compare 1 out-native.wav
cdparanoia -w 1 out-cdparanoia.wav
dd if=out-cdparanoia.wav bs=1 skip=44 2>/dev/null | shasum -a 256
```

この machine には光学ドライブが接続されていないため、ここでの CLI 実行は `no audio CD present: no IOCDMedia device was found` で終了する。ioctl の成功・転送内容は実ドライブがないため unit test できず、C 層は SDK struct と ioctl 呼び出しを最小限に留めている。

## Alternatives considered

- cdparanoia と libcdio を継続して同梱する案: 配布物の dylib 管理、プロセス起動、プラットフォーム差分が増え、単一の Go 実装という目的に反するため採用しない。
- OS ごとにリッピング判定まで実装する案: macOS と Windows で同じ品質保証を保ちにくく、テスト可能な共通コアとの責務分離を失うため採用しない。
- すぐに各 OS の ioctl reader まで追加する案: デバイス API の仕様調査と実機検証が未完了のため、このフェーズでは実施しない。

## Constraints

このフェーズで残る作業は、Windows の `IOCTL_CDROM_RAW_READ` reader、FLAC/ALAC の純 Go エンコーディング、AccurateRip 対応、ドライブオフセット DB の導入である。現在の encode step は従来どおり ffmpeg を使い、純 Go コアは 2352 bytes/sector の 16-bit little-endian stereo PCM WAV を一時ファイルへ書き出す。

セキュアモードは既定 27 セクタのブロック単位で読み取り、各ブロックを二重に比較する。一致するセクタはそのまま受理し、不一致のセクタだけを個別に設定回数まで再読して、従来どおり多数結果を採用する。ブロックサイズは `SecureReadOptions.BlockSize` で変更できる。burst モードはブロックごとに単一 read とし、オフセット補正でディスク境界外になったサンプルはゼロで埋める。

PCM はトラック全体をメモリへ保持せず、`SecureReadTrackTo` がブロックごとに `io.Writer` へ出力する。ブロックの読み取りキャッシュは次の出力ブロックへ進むと破棄されるため、保持量はトラック長に比例しない。Ripper は既知の PCM サイズで WAV ヘッダを先に書き、ネイティブ reader の出力を一時 WAV へ直接ストリームする。テストや小さな呼び出し元向けには、同じ処理を `[]byte` として返す `SecureReadTrack` を残す。
