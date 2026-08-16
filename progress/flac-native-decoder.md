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
- 増分 4（完了）: `Decoder.SeekSample` によるサンプル精度シーク、`pkg/audio` へのアダプタ経由統合（float32 出力への変換含む）、`mewkiz/flac` の完全撤去。詳細は以下。

## 増分4: シーク設計

`Decoder.SeekSample(sample int64) error`（`pkg/audio/flac/seek.go`）は2経路を持つ。

- **SEEKTABLE がある場合（高速経路）**: `Stream.SeekTableRaw` に保持していた生バイトをこの時点で初めてパースする（18バイト/点: 先頭サンプル番号8バイト＋`AudioStart`からのバイトオフセット8バイト＋フレームサンプル数2バイト、いずれもビッグエンディアン）。先頭サンプル番号が `0xFFFFFFFFFFFFFFFF` のプレースホルダー点は無視し、目的サンプル以下で最大のサンプル番号を持つ点へ直接シークする。
- **SEEKTABLE が無い場合（バイナリサーチ経路）**: `[AudioStart, fileEnd)` を対象に二分探索する。各候補バイト位置から前方走査し、`0xFF` 候補バイトごとに `ParseFrameHeader` を試して同期コード＋CRC-8 検証に成功した位置を「有効なフレームヘッダ」と確定する（CRC-8 検証込みなので偽陽性の同期一致を弾ける）。見つかったフレームの先頭サンプル番号で `target` との大小を比較し範囲を絞り込む。

どちらの経路でも、着地したバイト位置から `decodeFrame` でフル デコードしながら前進し、目的サンプルを含むフレームに到達したら、そのフレームの先頭を `target - frameStart` サンプルぶんトリムしてから次の `ReadFrame` に返す（`Decoder.pendingFrame`/`pendingSkip`）。この「フルデコードして前進」方式のため線形デコード＋読み飛ばしと**常にビット完全一致**する（等価性テストの担保根拠）。

フレーム先頭サンプルの算出（`frameStartSample`）は、固定ブロックサイズストリーム（`FrameHeader.VariableBlockSize == false`）ではヘッダのフレーム番号 × STREAMINFO の `MaxBlockSize`、可変ブロックサイズストリームではヘッダのサンプル番号をそのまま使う（RFC 9639 のフレームヘッダ仕様どおり）。

範囲外シークは負値・`TotalSamples` 超過のいずれもエラーを返す（クランプではなく明示エラーを選択）。`pkg/audio` 側のアダプタ（`flacAdapterDecoder.Seek`）は既存の `wavDecoder.Seek` 等に合わせてクランプしてから `SeekSample` を呼ぶため、プレイヤー層からは常に範囲内の呼び出しになる。

## 増分4: 統合で削除したもの

`pkg/audio/player.go` から `mewkiz/flac` 依存の補助コード一式を削除し、`pkg/audio/flac_decoder.go` の `flacAdapterDecoder`（`newFLACDecoder` 経由）に完全に置き換えた。

- **`remuxFLACFile()` とその起動元** — ID3v2 タグ付き FLAC を開いた2秒後に ffmpeg でユーザーの原本ファイルを書き換えていた破壊的処理。バックグラウンドで起動していたゴルーチンごと削除。新デコーダは ID3v2 ヘッダをネイティブにスキップするため不要。回帰防止として `pkg/audio/flac_decoder_test.go` に `TestPlayerFLACDecoder_ID3v2FileNeverModified` を追加（ID3v2 付きフィクスチャを `newFLACDecoder` 経由でフルデコードし、旧remuxが発火する2秒を超えて待っても内容・mtimeが変化しないことを検証。統合前は実際に旧remuxが発火し red だったことを確認済み）。
- **全フレームスキャン索引一式** — `flacFrameIndex` 型、`buildIndex()`、ディスクキャッシュ（`getFLACCachePath`/`saveFLACIndex`/`loadFLACIndex`/`getFLACCacheDir`）、公開関数 `BuildFLACIndex()`。新デコーダはシーク時にだけ二分探索するため、ライブラリ全曲を事前に全読みする必要が消えた。
- **`reflect`+`unsafe` によるプライベートフィールド注入** — `applySeekTable()`、`flacStreamReadSeeker`/`flacStreamDataStart`/`flacStreamSetSeekTable`。mewkiz の非公開フィールドへ `unsafe.Pointer` 経由で書き込んでいた箇所を全廃。`player.go` から `reflect`/`unsafe` の import ごと削除。
- **ミッドストリーム ffmpeg フォールバック** — `switchToFFmpeg()` と `flacDecoder.Read` 内の呼び出し。新デコーダは panic せず必ず error を返すため、デコード開始後に別デコーダへ切り替える理由が無い。**オープン時のフォールバックのみ残した**（新デコーダが `NewDecoder` に失敗した場合だけ ffmpeg デコーダにフォールバックする、`player.go` の `.flac` ケース）。
- **`server/app_scanner.go` の `BuildFLACIndexes()` とその起動（`go a.BuildFLACIndexes()`）** — ライブラリスキャン後に全 FLAC を索引化するワーカープールごと削除。Wails バインディング（`BuildFLACIndexes`）、フロントエンドの呼び出し元（`bridge.ts` の `buildFLACIndexes`、設定画面の「FLACシークインデックスを構築」ボタンとその進捗UI一式、`ipc.ts`/`renderer.ts` の `flac-index-progress`/`flac-index-complete` リスナー）も合わせて削除。
- **`github.com/mewkiz/flac`・`github.com/mewkiz/flac/frame`・`github.com/mewkiz/flac/meta` の import と `go.mod` の依存** — `go mod tidy` で `mewkiz/flac`・`mewkiz/pkg` を go.sum から完全除去。`go list -deps` で未リンクを確認したうえで `index.html` のライセンス一覧からも該当2行を削除。
- `detectID3v2Size` — 新デコーダが ID3v2 を自前で処理するため未使用化し削除。

`ReadUnary` は現状 1 ビットずつのループで、Rice 復号を載せた後にバイト単位スキャンへ最適化する余地がある（正しさには影響しない）。

## 増分3で得た知見

- **フレーム CRC-16 の算出には「実際に消費したバイト」の追跡が要る。** `BitReader` は内部に 4096 バイトの先読みバッファを持つため、次フレームの CRC-16 を読む時点では既に次フレームの先頭バイトまで内部バッファに入っていることがある。`bufio` などラップ側の Read 呼び出し単位で生バイトを記録すると、この先読み分まで巻き込んで誤ったバイト列になる。そこで `BitReader` 自身に `StartCapture`/`StopCapture` を実装し、ビット単位の消費（`ReadBits` 系・`Align`・`ReadRawBytes`）が実際に 1 バイト分完了した瞬間だけを記録するようにした。フレームヘッダの CRC-8（既存実装）は手動で raw バイトを積んでいたが、フレーム本体は個々の読み出し呼び出しが多すぎて同じ手法は取れないため、この汎用キャプチャ機構を追加した。
- **二重バッファリングは「ストリーム終端」の判定を壊す。** 当初 `Decoder` は `rs` を `bufio.Reader` でラップし、`BitReader` はさらにその上に独自バッファを持つ構成にしていた。`ReadFrame` の EOF 判定を `bufio.Reader.Peek(1)` で行ったところ、`bufio` 側のバッファが枯渇した時点で `io.EOF` を返すが、その時点で `BitReader` 内部バッファには最後のフレーム（部分ブロック）のバイトがまだ残っている、というケースが発生した。44.1kHz/16bit/モノラル・圧縮レベル 0 のフィクスチャで最終フレーム（648 サンプル）が丸ごと欠落する形で顕在化し、受け入れテストのビット完全一致検証がこれを検出した。修正は `BitReader.AtEOF()` を追加して内部バッファの消費状況を直接確認する方式に変え、`bufio` の中間層自体を廃止（`BitReader` が直接 `io.ReadSeeker` を読む）した。**教訓: バッファ付きリーダーを多段に重ねるときは、どの層の「バッファが空」を終端判定に使うか必ず突き合わせること。** 受け入れテストのフィクスチャ行列に「圧縮レベル 0（＝小さいブロックサイズ、割り切れない曲長になりやすい）」を含めていなければこのバグは見つからなかった可能性が高い。
