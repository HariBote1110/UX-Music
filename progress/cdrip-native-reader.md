# CD リッピング純 Go コアと OS seam

## Decision

cdparanoia の実行ファイルと libcdio dylib を同梱して呼び出す方式を段階的に置き換えるため、リッピング判定・再読・オフセット補正・PCM WAV 出力を `pkg/cdrip` の OS 非依存 Go コアとして実装する。ドライブへアクセスする部分は `DiscReader` に限定し、Ripper は reader factory が設定された場合だけ新コアを使う。factory がない現状は cdparanoia 経路をそのまま維持する。

## Alternatives considered

- cdparanoia と libcdio を継続して同梱する案: 配布物の dylib 管理、プロセス起動、プラットフォーム差分が増え、単一の Go 実装という目的に反するため採用しない。
- OS ごとにリッピング判定まで実装する案: macOS と Windows で同じ品質保証を保ちにくく、テスト可能な共通コアとの責務分離を失うため採用しない。
- すぐに各 OS の ioctl reader まで追加する案: デバイス API の仕様調査と実機検証が未完了のため、このフェーズでは実施しない。

## Constraints

このフェーズで残る作業は、macOS の `DKIOCCDREAD` / `DKIOCCDREADTOC` reader、Windows の `IOCTL_CDROM_RAW_READ` reader、FLAC/ALAC の純 Go エンコーディング、AccurateRip 対応、ドライブオフセット DB の導入である。現在の encode step は従来どおり ffmpeg を使い、純 Go コアは 2352 bytes/sector の 16-bit little-endian stereo PCM WAV を一時ファイルへ書き出す。

セキュアモードは既定 27 セクタのブロック単位で読み取り、各ブロックを二重に比較する。一致するセクタはそのまま受理し、不一致のセクタだけを個別に設定回数まで再読して、従来どおり多数結果を採用する。ブロックサイズは `SecureReadOptions.BlockSize` で変更できる。burst モードはブロックごとに単一 read とし、オフセット補正でディスク境界外になったサンプルはゼロで埋める。

PCM はトラック全体をメモリへ保持せず、`SecureReadTrackTo` がブロックごとに `io.Writer` へ出力する。ブロックの読み取りキャッシュは次の出力ブロックへ進むと破棄されるため、保持量はトラック長に比例しない。Ripper は既知の PCM サイズで WAV ヘッダを先に書き、ネイティブ reader の出力を一時 WAV へ直接ストリームする。テストや小さな呼び出し元向けには、同じ処理を `[]byte` として返す `SecureReadTrack` を残す。
