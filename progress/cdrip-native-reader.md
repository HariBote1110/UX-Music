# CD リッピング純 Go コアと OS seam

## Decision

cdparanoia の実行ファイルと libcdio dylib を同梱して呼び出す方式を段階的に置き換えるため、リッピング判定・再読・オフセット補正・PCM WAV 出力を `pkg/cdrip` の OS 非依存 Go コアとして実装する。ドライブへアクセスする部分は `DiscReader` に限定し、Ripper は reader factory が設定された場合だけ新コアを使う。factory がない現状は cdparanoia 経路をそのまま維持する。

## Alternatives considered

- cdparanoia と libcdio を継続して同梱する案: 配布物の dylib 管理、プロセス起動、プラットフォーム差分が増え、単一の Go 実装という目的に反するため採用しない。
- OS ごとにリッピング判定まで実装する案: macOS と Windows で同じ品質保証を保ちにくく、テスト可能な共通コアとの責務分離を失うため採用しない。
- すぐに各 OS の ioctl reader まで追加する案: デバイス API の仕様調査と実機検証が未完了のため、このフェーズでは実施しない。

## Constraints

このフェーズで残る作業は、macOS の `DKIOCCDREAD` / `DKIOCCDREADTOC` reader、Windows の `IOCTL_CDROM_RAW_READ` reader、FLAC/ALAC の純 Go エンコーディング、AccurateRip 対応、ドライブオフセット DB の導入である。現在の encode step は従来どおり ffmpeg を使い、純 Go コアは 2352 bytes/sector の 16-bit little-endian stereo PCM WAV を一時ファイルへ書き出す。

セキュアモードは各セクタを二重以上に読み、同値なら受理する。不一致時は設定回数まで再読して多数結果を採用し、疑わしい範囲と復旧不能範囲を report する。burst モードは単一 read とし、オフセット補正でディスク境界外になったサンプルはゼロで埋める。
