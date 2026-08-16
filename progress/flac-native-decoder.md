# FLAC デコーダの自作（mewkiz/flac からの置き換え）

## 決定

`pkg/audio/flac` に FLAC デコーダを Go で自作し、`github.com/mewkiz/flac` を置き換える。既存の `pkg/audio/player.go` の経路には一切触れず、新パッケージとして並走させ、ビット一致検証に合格してから切り替える。

### mewkiz/flac をやめる理由

ライブラリを使いながら、ライブラリを騙すための補助コードが自作デコーダ級の分量になっていた。負債は 3 つ。

1. **原本ファイルの破壊的書き換え** — ID3v2 タグ付き FLAC を mewkiz が開けないため、`remuxFLACFile()` が ffmpeg でユーザーの原本を remux して置き換えている（`player.go` の `newFLACDecoder`）。自作なら先頭で `fLaC` シグネチャを探すだけで対応でき、この処理ごと不要になる。
2. **全フレームのフルスキャン索引** — SeekTable を持たない FLAC のシークのために `buildIndex()` が全フレームを走査し、ディスクキャッシュまで持っている。自作ならフレームヘッダ同期＋CRC-8 検証＋二分探索でシークできるので、索引とキャッシュの両方が消える。
3. **`reflect` + `unsafe` による非公開フィールド注入** — `applySeekTable()` が mewkiz の非公開 SeekTable フィールドに直接書き込んでいる。mewkiz を更新した瞬間に壊れる。

加えて、`Decoder` インターフェースが `Read([]byte)`（int16 固定）のため 24bit FLAC が `sample >> (bps-16)` でディザなし切り捨てされていた。自作デコーダは float32 をネイティブに出力し、EQ・BS.1770 ラウドネス補正へ精度を落とさず渡す。

### 実装言語に Go を選んだ理由（Rust を却下した理由）

- **GC 論法が成立しない。** デコーダは `decoderLoop` の独立ゴルーチンでリングバッファに書くだけで、PortAudio コールバック `processAudio` はデコーダに触れない。さらに `waitForPrefill` が最大 150ms 先読みしてから `stream.Start()` する（`progress/first-playback-warmup.md`）。デコーダ側は数十 ms 遅れても音に影響しない構造で、GC 停止耐性がすでに確保されている。
- **速度差が効く場所が無い。** FLAC デコードは Rust なら 1.5〜2.5 倍速いが、Go でも実時間の数十〜百倍。しかも CPU が効いていた唯一の場所（`buildIndex` の全曲スキャン）は自作によって消滅する。
- **`go test -race` の検査範囲から外れる。** このプロジェクトの検証は `make test-go` の `-race` に集約されている。一番バグりやすい新規コードだけがその外に出るのは割に合わない。
- **共有先が無い。** Rust の最大の利点は Swift 側（iOS/tvOS/watchOS）とデコーダコアを共有できることだが、Swift 側は AVFoundation が FLAC を再生でき、`DownloadedTrackFormatSniffer.swift` のように形式判定しかしていない。共有する相手が存在しない。
- FFI 境界を越える panic は未定義動作で `catch_unwind` の定型作業が必要。Go なら `decoderLoop` で `recover()` するだけで、これは mewkiz の panic 対策として元々必要だった形と同じ。

## 却下した代替案

- **Rust + FFI で自作** — 上記のとおり利点が成立せず、Makefile/CI にツールチェーンとアーキ別静的ライブラリ生成が増えるコストだけが残る。
- **symphonia（Rust）を FFI で利用** — mewkiz より高品質なのは事実だが、「他人のライブラリに振り回される」という当初の問題を維持したまま FFI 境界を足すだけで、制御権を取り戻すという動機と方向が逆。
- **すべて ffmpeg に寄せる** — 実装コストはほぼゼロだが、曲ごとのプロセス起動とシーク時の再起動を受け入れることになる。ローカル再生の品質と制御権を優先して不採用。
- **MP3 デコーダも自作** — 非可逆コーデックはハイブリッドフィルタバンク・IMDCT・ビットリザーバで 4,000 行級、しかも ISO 準拠は許容誤差ベースでビット一致検証ができない。そして現に困っているギャップレス再生は、Xing/Info/LAME タグの delay/padding と iTunSMPB を読んでトリムするだけで go-mp3 のまま解決できる。自作の動機にならない。

## 制約・注意点

- **ffmpeg 依存は消えない。** m4a/aac/ogg のデコード、リモート URL（YouTube itag 251/opus）、`/v1/remote/relay` の AAC 変換、`?stream=aac` で使い続ける。自作の動機は依存削減ではなく、ローカル再生の品質と制御権に置くこと。
- **検証は二重の経路を使う。** (1) `flac -d` の出力とバイト単位で一致すること、(2) デコード後 PCM の MD5 が STREAMINFO の MD5 フィールドと一致すること。(2) はデコーダ自身による自己検証で、外部ツール不在の環境でも効く。
- **テスト用 FLAC はリポジトリに置かない。** `fixtures_test.go` が ffmpeg（sine + anoisesrc の `amix`）と `flac` CLI でその場生成し、`TestMain` 所有の一時ディレクトリにパラメータキーで memo 化する。CLI 不在時は `t.Skip`（`server/app_remote_relay_test.go` の `requireFFmpegForTest` の前例に準拠）。純粋な正弦波や無音は残差が退化して後段の Rice/LPC を検証できないため、フィクスチャは必ずノイズを混ぜた非自明な内容にする。
- **仕様は RFC 9639 を正とする。** フレームヘッダのサンプルサイズコード `0x7` は旧 FLAC 仕様では reserved だが RFC 9639 では 32bit。実装は RFC 9639 に従っている。
- **panic させない。** 破損入力に対して必ず error を返す。スライス添字はすべて明示的に境界チェックする（mewkiz は連打スキップ時に `slice bounds out of range` で panic した実績がある — `markdown/issue-wails-playback-ui-desync-unresolved.md`）。`unsafe` と `reflect` は使わない。

## 進捗

- 増分 1（完了）: MSB ファーストのビットリーダー（`ReadBits` / `ReadBitsSigned` / `ReadUnary` / `ReadUTF8Uint64` / アラインメント）
- 増分 2（完了）: ID3v2 スキップ、`fLaC` シグネチャ、メタデータチェーンと STREAMINFO の解析（SEEKTABLE は生バイトで保持）、フレームヘッダ解析と CRC-8 検証
- 増分 3（完了）: サブフレーム（CONSTANT / VERBATIM / FIXED / LPC）、RESIDUAL（Rice 符号化、method 0/1、エスケープ）、ステレオデコリレーション（left/side・right/side・mid/side）、フレーム CRC-16 検証、公開 API（`NewDecoder` / `Info` / `ReadFrame` / `Close`）。`flac -d` の出力とのビット完全一致、および STREAMINFO MD5 の自己検証に合格（44.1kHz/16bit・96kHz/24bit・モノラル、圧縮レベル 0/5/8、`-m` による mid/side、1 ブロック未満の極短ファイルの各条件で確認）。
- 増分 4 以降（未着手）: シーク、`pkg/audio` への統合（float32 出力への変換含む）

`ReadUnary` は現状 1 ビットずつのループで、Rice 復号を載せた後にバイト単位スキャンへ最適化する余地がある（正しさには影響しない）。

## 増分3で得た知見

- **フレーム CRC-16 の算出には「実際に消費したバイト」の追跡が要る。** `BitReader` は内部に 4096 バイトの先読みバッファを持つため、次フレームの CRC-16 を読む時点では既に次フレームの先頭バイトまで内部バッファに入っていることがある。`bufio` などラップ側の Read 呼び出し単位で生バイトを記録すると、この先読み分まで巻き込んで誤ったバイト列になる。そこで `BitReader` 自身に `StartCapture`/`StopCapture` を実装し、ビット単位の消費（`ReadBits` 系・`Align`・`ReadRawBytes`）が実際に 1 バイト分完了した瞬間だけを記録するようにした。フレームヘッダの CRC-8（既存実装）は手動で raw バイトを積んでいたが、フレーム本体は個々の読み出し呼び出しが多すぎて同じ手法は取れないため、この汎用キャプチャ機構を追加した。
- **二重バッファリングは「ストリーム終端」の判定を壊す。** 当初 `Decoder` は `rs` を `bufio.Reader` でラップし、`BitReader` はさらにその上に独自バッファを持つ構成にしていた。`ReadFrame` の EOF 判定を `bufio.Reader.Peek(1)` で行ったところ、`bufio` 側のバッファが枯渇した時点で `io.EOF` を返すが、その時点で `BitReader` 内部バッファには最後のフレーム（部分ブロック）のバイトがまだ残っている、というケースが発生した。44.1kHz/16bit/モノラル・圧縮レベル 0 のフィクスチャで最終フレーム（648 サンプル）が丸ごと欠落する形で顕在化し、受け入れテストのビット完全一致検証がこれを検出した。修正は `BitReader.AtEOF()` を追加して内部バッファの消費状況を直接確認する方式に変え、`bufio` の中間層自体を廃止（`BitReader` が直接 `io.ReadSeeker` を読む）した。**教訓: バッファ付きリーダーを多段に重ねるときは、どの層の「バッファが空」を終端判定に使うか必ず突き合わせること。** 受け入れテストのフィクスチャ行列に「圧縮レベル 0（＝小さいブロックサイズ、割り切れない曲長になりやすい）」を含めていなければこのバグは見つからなかった可能性が高い。
