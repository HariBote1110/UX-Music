# GET /v1/remote/relay（Phase 3-3 送信側・YouTube 音声中継）

## Decision

- **エンドポイント**: `GET /v1/remote/relay`（`Authorization: Bearer` 必須、`/v1/identity`・`/v1/pairing/*` のような公開扱いにはしない）。認証は既存の `deviceAuthMiddleware` にそのまま乗る（`isPublicLANEndpoint` に追加していない）。
  - **ヘッドレス時**: `CurrentServerMode() != ModeGUI` なら常に `404`（`/v1/local/shutdown` と同じ「ルートごと存在しないふりをする」パターン）。認証済みリクエストでも 404。
  - **中継ソース非アクティブ時**: `409 Conflict` を `{"error":{"code":"error","message":"no active relay source"}}`（`writeAPIError` の共通形式）で返す。5xx ではなく 409 を選んだ理由: クライアント側の「今は再生していないので待つ／ポーリングする」的リトライが正しい振る舞いであり、サーバ障害ではないため。
  - **レスポンス**: `Content-Type: audio/aac`、chunked（`http.Flusher` で明示的に `Flush()`）、ボディは AAC-LC ADTS の連続ストリーム。
- **エンコーダ**: 内蔵の `locateFfmpeg()`（`server/app_remote.go`、`/v1/remote/file` の bitrate 変換と共通）で見つけた ffmpeg を `-f f32le -ar <rate> -ac <channels> -i pipe:0 -c:a aac -b:a 256k -f adts pipe:1` として起動し、標準入力に生 PCM（interleaved float32 LE）を流し込み、標準出力から ADTS フレームを読んで購読者へブロードキャストする。stdin→stdout の単純なパイプ方式を採用（ffmpeg 自前ライブラリの cgo バインディングなどは導入しない）。
  - ビットレートは計画書 3-3 の指示どおり **256kbps 固定**（`/v1/remote/file` のようなクライアント別ビットレート選択はしない — 放送型で全クライアント共通の1本のストリームのため）。
  - **重要な落とし穴（実測で発覆）**: `-probesize`/`-analyzeduration`/`-flush_packets` を付けないと、**stdin を開いたまま断続的に PCM を流し込んでも ffmpeg は一切 stdout に書き出さず、stdin を close するまで無音**になる。ローカルで fifo を使い「0.3秒おきに8KB書き込み→都度ファイルサイズ確認」という再現手順で検証済み（`/tmp/pcmfifo*` を使った使い捨て実験、ffmpeg 8.0.1 / macOS）。原因は ffmpeg 側の内部 avio バッファ＋probe/analyze の待ち合わせで、出力ファイルが 33KB 程度（1回のバッファ分）に達するまで書き込みが起きなかったため、短い中継では「ずっと何も届かない」ように見える。
    - `-probesize 32 -analyzeduration 0`: `-f f32le` で明示している以上プローブは不要なので即座にデコードを開始させる。
    - `-flush_packets 1`: エンコードされた ADTS パケットを都度 stdout へ flush させる。
    - この3つを揃えて初めて、0.3秒間隔で流したテストデータが即座に（数十ms〜数百ms遅延で）出力側に反映されることを確認した（`server/app_remote_relay_test.go` の `TestRemoteRelayEngine_SingleClientReceivesADTSBytes` がこの構成でのみ 5秒以内に成功する）。
  - レイテンシは概算で「PCM プッシュ間隔＋AAC エンコーダのプライミング遅延（約1024〜2048サンプル≒25〜45ms@44.1kHz）＋HTTP chunked 転送」程度。実測は合成 PCM（440Hz サイン波、2048フレームずつ5ms間隔でプッシュ）で数百ms以内に最初の ADTS バイトを受信できることを確認済みだが、**実際の Core Audio プロセスタップ経由の PCM での end-to-end レイテンシは未計測**（後述の未確定を参照）。
- **ファンアウト設計**: `relayEngine`（`server/app_remote_relay.go`）が唯一のエンコード経路を持ち、購読者ごとに `chan []byte`（バッファ32）を持つ。`broadcast()` は各チャンネルへ非ブロッキング送信（`select default` で詰まっていれば drop）にし、遅いクライアント1台が他のクライアントやエンコードパイプライン自体を停滞させないようにした。
  - **後発クライアントはライブエッジから**: `Subscribe()` はチャンネル登録時点より前の chunk を一切バッファ・再送しない。過去ログを保持する設計にしなかったのは、計画書の「放送型」要求（同じ音を全員が同時に聴く）と、バックログ再生に伴うレイテンシ増大・複雑化を避けるため。
  - **切断の独立性**: HTTP ハンドラは `r.Context().Done()` とチャンネル受信を `select` し、クライアント切断時は `unsubscribe()` のみを行い、他の購読者やエンコードパイプラインには一切影響しない。エンジン全体の `Stop()` は明示的に呼ばれた場合、または ffmpeg プロセスが終了した場合（`cmd.Wait()` の完了）にのみ発生する。
- **ゲーティング**: `CurrentServerMode()` を使う既存パターンをそのまま踏襲（新しいモード判定機構は作らない）。
- **capability 広告**: `/v1/identity` の `capabilities` に `remote.relay.v1` を **GUI モードのときだけ** 追加する（`server/app_identity.go` の `identityCapabilities()`）。`syncCapabilities()` 自体（`server/app_sync_protocol.go`）は sync プロトコル用の固定リストのままにし、relay 用の条件分岐は identity 側だけに閉じた。
- **`/v1/remote/state` の拡張**: 既存フィールドはそのまま、追加で `relay: {"active": bool, "title": string, "thumbnail": string}` を常に含める（GUI/ヘッドレス問わず。ヘッドレスでは `relayEngine` が起動されないため常に `active: false`）。既存クライアントは未知キーを無視する前提のため後方互換。

## Wiring seam（テスト用インジェクションと実配線）

- `RelayPCMSource` インタフェース（`ReadPCM(dst []float32) (n int, ok bool)` / `SampleRate()` / `Channels()`）が唯一の依存点。テストは `chanRelayPCMSource`（`server/app_remote_relay_test.go`）で合成サイン波を注入し、Core Audio ハードウェアなしでエンジン・HTTP 層・ゲーティングを検証している。
- `pkg/audio/processtap_darwin.go` の `ProcessTapCapture`（`ReadSamples([]float32) int` / `SampleRate()` / `Channels()`）は非常によく似た形をすでに持っているが、**プル型・非ブロッキング**（リングバッファが空なら 0 を返す）である一方、`RelayPCMSource.ReadPCM` は現状ブロッキング前提で書いている（`pumpPCM` は `n==0` のとき busy loop で継続する実装にしてあるため、実際には非ブロッキングソースを渡しても動く設計にはなっている）。
- **実配線は本チケットでは行っていない**。理由と残作業は次の「未確定」を参照。

## Alternatives considered

- **cgo で libavcodec/libfdk_aac を直接バインドしてプロセス内エンコード** → ffmpeg バイナリはすでに `config.FFmpegPath` としてアプリに同梱されており（`/v1/remote/file` のビットレート変換で実績あり）、新規の cgo 依存・ビルド複雑化を避けるため不採用。プロセス起動のオーバーヘッドは中継開始時の1回だけで、ストリーミング自体はパイプ経由の低レイテンシ I/O のため許容範囲と判断。
- **Opus** → 計画書どおり AAC-LC を第一候補として採用（tvOS/iOS のハードウェアデコード前提）。Opus は「互換性検証後の代替」と明記されているため今回は実装せず。
- **購読者ごとに独立した ffmpeg プロセス**（1クライアント=1エンコード）→ 「放送型」（1本の音源を全員が同時に聴く）という計画書の前提と矛盾する上、クライアント数に比例して CPU コストが増える。1本のエンコードを fan-out する設計にした。
- **後発クライアントへの直近バッファ再送**（GOP的な先頭キーフレーム待ちに近い発想）→ ライブ配信としての一貫性（全員が同じ時点を聴く）を優先し、バックログ保持はしない。

## Constraints / Gotchas

- ffmpeg が見つからない環境（`locateFfmpeg()` が失敗）では `Start()` がエラーを返し、中継は一切開始されない（`/v1/remote/relay` は 409 のまま）。テストは `exec.LookPath("ffmpeg")` が失敗する環境で ffmpeg 依存のケースを `t.Skip` する（`server/app_remote_relay_test.go` の `requireFFmpegForTest`）。他の認証/ゲーティング/409 系テストは ffmpeg 不要で常に実行される。
- `relayEngine` はプロセス単位のシングルトン（`remoteRelay` パッケージ変数）。1マシン1インスタンス・1回に1本の YouTube 再生という計画書の前提（明文化事項2・6）と一致するため、複数ソースの同時中継はサポートしない。`Start()` は常に前のソースを `Stop()` してから開始する。
- `AudioGetStatus()` の title/artist/album は YouTube 再生かローカル再生かを区別しないため、`relay` ブロックの title/thumbnail は `relayEngine.Start()` の呼び出し側が明示的に渡した値をそのまま保持する（`mediaTitle` 等を横取りしない設計）。

## 未確定（実装時に決めて本紙・SSoT に反映するもの、Phase 3-3 の「未確定」節に対応）

- **実タップ→中継への配線が未接続**。今回投入したのはエンジン・HTTP・ゲーティング・capability 広告・state 拡張のみで、実際に「GUI で公式 IFrame 再生が始まったら `remoteRelay.Start(...)` を呼ぶ」トリガー自体は存在しない。理由:
  1. フロントエンド（`src/renderer/`）側で「YouTube 公式 embed の再生が開始/終了した」という Go 側へのイベント通知経路が現状見当たらない（`server/app_remote_youtube.go` は URL 解決・ライブラリ追加のみで、再生状態そのものは持っていない）。本チケットのスコープは Go 側（`server/`・`internal/`・`pkg/`）に限定されているため、`src/renderer/` の変更は行っていない。
  2. `pkg/audio.ProcessTapCapture`（Core Audio プロセスタップ）は darwin 専用の cgo 実装で、`cmd/spike-processtap/` のスパイクでのみ動作実績があり、本番の再生パイプラインには未統合。実機（Core Audio の権限ダイアログ、集約デバイス構築、デフォルト出力デバイス変更時の再構築など）での検証が必須で、このワークツリー上のヘッドレステストでは検証不可能。
  3. `ProcessTapCapture` は非ブロッキング・プル型（リング空なら `ReadSamples` が 0 を返す）なので、`RelayPCMSource` アダプタを書く際はポーリング間隔（busy loop の sleep 幅）をどう決めるかの実測チューニングが必要（本チケットの `pumpPCM` は `n==0` のとき即座に再ループするため、実配線時は CPU 使用率を見ながら短い sleep を挟むかどうか判断すること）。
- **エンコードコーデックの最終確定**は計画書どおり「AAC-LC 想定、レイテンシ実測後」のまま。今回の実測はあくまで合成 PCM でのローカルテストであり、実タップ音声・実機 tvOS/iPhone 受信でのエンドツーエンドレイテンシは未計測。
- **フロントエンドから Go への「再生中の YouTube 動画」メタデータ（曲名・サムネイル）受け渡し経路**も未定義。現状 `relayEngine.Start(source, title, thumbnail)` は呼び出し側が値を渡す形にしてあるが、実際に何が呼ぶか（Wails バインディング経由の新規メソッドを想定）は本チケットのスコープ外。
- 受信側（TV/iPhone）の実装・「PC で再生中の YouTube をローカル再生パイプラインへの割り込みとして提示する」UI は計画書どおり別チケット（スコープ外）。

## 追記（実タップ→中継の配線を接続）

上記「未確定」の1〜3を解消し、GUI モードでは実際に「公式 embed 再生開始 → Core Audio プロセスタップ → relayEngine」まで一本につながる状態にした。

- **トリガー経路**: 新しい Wails バインディング `App.NotifyYouTubePlaybackState(active bool, title string, thumbnailURL string) error`（`server/app_remote_relay_notify.go`）。ヘッドレスモードでは `CurrentServerMode() != ModeGUI` で即 `nil` を返す no-op（`/v1/remote/relay` 自体のゲートと同じパターン）。
  - フロントエンドは `src/renderer/js/features/player.ts` の `playEmbed()` 内、既存の `AudioStartWebViewTap` 呼び出し箇所（`onPlaying` コールバック、タップ確立トリガー）に隣接して `notifyRelayPlaybackState(true, song.title, resolveRelayThumbnailURL(song))` を追加。曲終了（`onEnded`）と明示停止（`stop()` の `wasEmbed` 分岐）で `notifyRelayPlaybackState(false, '', '')` を呼ぶ。一時停止（`pauseCurrent()`）では呼ばない — 既存の `AudioStartWebViewTap` 自体もポーズ中はタップを張ったままにする設計（コメント「タップは張ったまま、埋め込みプレイヤー側を一時停止する」）を踏襲し、ポーズ中も中継を維持する。
  - 中継用タップの成否はローカル再生（`AudioStartWebViewTap`）と独立させ、await せず fire-and-forget にした。中継はあくまで付随機能であり、失敗してもローカル再生を止めるべきではないため。
- **タップ対象**: `cmd/spike-processtap` の phase B（自プロセスではなく子プロセス＝WKWebView 相当のヘルパーをタップする設計）と、既存の `AudioStartWebViewTap`（`server/app_audio.go`）が踏襲している「このアプリが所有する WebKit ヘルパー PID を都度解決してタップする」方式をそのまま流用した。embed は Wails の WebView 内で再生されるため、タップ対象は「YouTube 再生プロセス」ではなく「このアプリの WebKit ヘルパープロセス」であり、`audio.WebKitHelperPIDs()` で解決する。ローカル再生用タップ（`a.audioPlayer.PlayProcessTap`、スピーカー出力）とは別に、中継専用の `ProcessTapCapture` を独立に起動する（同じヘルパーを2つの独立したアグリゲートデバイスがタップする形）。処理を分離した理由は、`a.audioPlayer` 内部の `Player` 型に依存せず `server` パッケージ側だけで完結させたかったため（`Player.PlayProcessTap` はローカル再生パイプライン＝EQ/gain/FFT 前提の型で、relay の PCM だけを横取りする用途には合わない）。
- **タップアダプタ**: `pkg/audio/processtap_capture.go` にプラットフォーム非依存の `TapCapture` インタフェース（`ReadSamples`/`SampleRate`/`Channels`/`Stop`）を切り出し、darwin では `StartProcessTapCapture` が既存の `StartProcessTap` をそのまま返し、他プラットフォームでは非対応エラーを返すスタブを追加。`server/app_remote_relay_source.go` の `processTapRelaySource` がこれを `RelayPCMSource` へ橋渡しする。`ReadSamples` が非ブロッキングで 0 を返す間は 5ms スリープしてから再ポーリングし（`relayEngine.pumpPCM` の busy loop 対策、未確定項目3への回答）、明示的な `Close()` でのみ枯渇（`ok=false`）を報告する（タップ自体は「今は何もない」を「終わった」と区別できないため、終了判断は呼び出し側＝`NotifyYouTubePlaybackState` に一元化した）。
- **ライフサイクル**: `NotifyYouTubePlaybackState` はパッケージ変数 `relayTapSource`/`relayTapCapture`（`relayTapMu` で保護、`remoteRelay` 自体と同じくプロセス単位のシングルトン前提）を保持し、呼び出しのたびにまず前回のタップ・中継を止めてから必要なら新しく始める（`relayEngine.Start` 自身の「前のソースを Stop してから開始」という既存方針と揃えた）。PID 解決関数・タップ起動関数はパッケージ変数（`relayWebKitHelperPIDs`/`relayStartProcessTap`）として注入可能にし、Core Audio 実機なしで CI 上でもライフサイクル（開始/停止/切替時の旧タップ停止/ヘルパー未検出時のエラー/タップ起動失敗時のエラー）を検証できるようにした（`server/app_remote_relay_notify_test.go`、フェイクは `server/app_remote_relay_source_test.go` の `fakeTapCapture`）。
- **メタデータ**: `NotifyYouTubePlaybackState` の `title`/`thumbnailURL` はそのまま `remoteRelay.Start(source, title, thumbnailURL)` に渡り、既存の `/v1/remote/state` の `relay` ブロックへ反映される（配線のみで `app_remote.go` 側の変更は不要だった）。

### 実機検証で残っているもの（本チケットでは検証不可能）

- **実タップ音声での動作確認**: `processTapRelaySource` のポーリング・枯渇制御ロジックはフェイクで単体テスト済みだが、実際の `ProcessTapCapture`（Core Audio 実機・システム音声録音の権限ダイアログ）を通した end-to-end 動作（`/v1/remote/relay` を叩いて実際に AAC が聞こえるか）は on-machine 検証が必須。
- **end-to-end レイテンシの実測**: 依然として合成 PCM でのローカルテストのみ。実タップ→ffmpeg→HTTP chunked→tvOS/iPhone 受信側までの実測レイテンシは未計測。
- **同一ヘルパーに対する二重タップの挙動**: ローカル再生用タップ（`AudioStartWebViewTap` 経由）と中継用タップ（`NotifyYouTubePlaybackState` 経由）は同じ WebKit ヘルパーを独立した2つのアグリゲートデバイスでタップする設計にした。理論上は Core Audio のプロセスタップは複数リスナーを許容するはずだが、実機での CPU 負荷・音ズレ・タップ確立の競合有無は未検証。問題が出た場合は「ローカル再生用タップのリングバッファを relay とも共有する」設計へ変更する必要がある。
- **出力デバイス切替時の再構築**: `ProcessTapCapture` はデフォルト出力デバイス変更時に再構築が必要（`processtap_darwin.go` のコメント参照）。ローカル再生用タップ側はこのフックを持つ想定だが、中継用タップ側に同様の再構築フックは今回実装していない（出力デバイスを切り替えると中継が無音のまま止まる可能性がある）。
- **受信側（TV/iPhone）実装・UI**: 引き続き別チケット（スコープ外）。
