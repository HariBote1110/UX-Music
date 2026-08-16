# TVによるYouTube LAN中継の受信（Phase 3-3 受信側）

対象: `UX-Music-Mobile/`のみ（`server/`等Goサイドは送信側として既に別エージェントが実装済み・マージ済み）。

## Decision

- **可否判定の分離**: `TVRelayModel`（`UX-Music-TV/TVRelayModel.swift`）を新設し、以下の純粋型でTDD:
  - `TVRelayCapability.isPresent(in:)` — `GET /v1/identity`の`capabilities`配列に
    `"remote.relay.v1"`が含まれるか。
  - `TVRelayStateBlock.parse(fromStateJSON:)` — `GET /v1/remote/state`の追加型`relay`
    ブロック（`{"active","title","thumbnail"}`）のパース。キー欠落は例外ではなく
    `.inactive`として扱う（サーバー側もこのブロックを追加型として設計しているため）。
  - `TVRelayAvailability.isAvailable(capabilities:relay:)` — 両方を満たすときのみ`true`。
    片方だけでは表示しない（capability無し＝古いホスト、active=false＝ホストは対応して
    いるが今何も再生していない、のどちらも同じ「棚を出さない」結果になる）。
  - `TVRelayModel`本体（`ObservableObject`）は`capabilities`を初回のみ取得しキャッシュ
    （サーバーモードは接続中に変化しない前提）、`relay`ブロックは5秒間隔でポーリングし直す
    （ホスト側でユーザーがYouTube再生を開始/停止するたびに変化するため）。

- **iOS側クライアント拡張**: `RemoteAPIClient`に`fetchIdentityCapabilities()`と
  `relayRequest()`を追加。
  - `relayRequest()`は`GET /v1/remote/relay`に対する認証済み`URLRequest`を返す。
    Goサーバーの`server/app_apierror.go`の`isMediaQueryTokenEndpoint`を確認したところ、
    `?token=`クエリ代替を受け付けるのは`/v1/remote/file`と`/v1/remote/artwork/`のみで、
    `/v1/remote/relay`は対象外——**`Authorization: Bearer`ヘッダのみ**で認証される。
    このため`artworkURL(artworkId:)`のような裸のURL文字列ではなく、ヘッダ付き
    `URLRequest`を返す設計にした。

- **UI（ブラウズ棚への統合）**: `TVBrowseView`に`relayModel.isAvailable`が`true`のときのみ
  表示される棚を追加（既存のアルバム棚・プレイリスト棚と同じ`TVShelfSection`パターンを
  流用、一番上に配置）。ローカライズキーは「PCで再生中のYouTube」（en: "YouTube Playing
  on PC"）。サムネイルは`TVArtworkImage`（ライブラリartwork id専用）を使わず、ホストが
  返すYouTube CDNのサムネイルURLを直接`AsyncImage`に渡す新設の`TVRelayCard`とした
  （公開インターネット上のURLでありLAN認証は不要なため）。

- **再生UI（ブロードキャスト型バナー）**: 選択すると`player.stop()`でローカル
  `MusicPlayerService`再生を止め、`TVRelayPlaybackController.start()`で中継を開始し、
  フルスクリーンの`TVRelayBannerView`へ遷移する。バナーはサムネイル・タイトルの表示のみで、
  シーク/スキップ等の操作は持たない——3-3の方針通り「PCが操作主体」であるため。
  - 退出は「戻る/メニュー」（tvOSのシステムジェスチャがSwiftUIの`fullScreenCover`を閉じる）
    または明示的な「終了」ボタン。どちらの経路でも`TVRelayBannerView.onDisappear`が
    `relayPlaybackController.stop()`を呼ぶため、ストリーム停止漏れが起きない一本の経路に
    集約した。
  - ホスト側が中継を停止した場合（`relayModel.isAvailable`が`false`に変化）もバナーを
    自動的に閉じる（`TVBrowseView`の`onChange(of: relayModel.isAvailable)`）。
  - `TVConnectedView`の`.onDisappear`（サインアウト等でブラウズ画面自体を離れるとき）でも
    `relayPlaybackController.stop()`を呼び、`remoteControlServer.stop()`と同じライフ
    サイクル管理に揃えた。

- **`AVPlayer`によるストリーム再生（認証・実装）**: `TVRelayPlaybackController`が
  `AVURLAsset`を`relayRequest()`のURL＋ヘッダから構築し、`AVPlayer`で再生する。
  - `Authorization`ヘッダを`AVURLAsset`に渡す標準的な方法である
    `AVURLAssetHTTPHeaderFieldsKey`は、確認した限りtvOS SDKの公開ヘッダ
    （`AppleTVSimulator26.5.sdk`）に宣言が無く、named constantとしてはコンパイルエラーに
    なった（iOSのAVFoundationヘッダには存在するが、tvOSでは非公開扱いの模様）。
    非公開ながら歴史的に多くのアプリで機能してきた生の文字列キー
    `"AVURLAssetHTTPHeaderFieldsKey"`を代わりに使用した。**この文字列キーがtvOS上の
    実際の`AVPlayer`で有効に機能するかは、シミュレータのコンパイル確認のみで、
    実機/実際のネットワーク越しの検証はできていない。**
  - `Content-Type: audio/aac`をサーバーが返す（`server/app_remote_relay.go`）ことに
    合わせ、`AVURLAssetOverrideMIMETypeKey`に`"audio/aac"`を明示（こちらはtvOS 17+の
    公開APIとして存在を確認済み）。

## Alternatives considered

- **`?token=`クエリでの認証**: `/v1/remote/file`/`artwork`と同様の裸URLで済ませたかったが、
  Goサーバーの`isMediaQueryTokenEndpoint`に`/v1/remote/relay`が含まれていないため不可。
  サーバー側の変更は担当外（別エージェント領域）のため、クライアント側でヘッダ付き
  `AVURLAsset`を使う設計に合わせた。
- **カスタム`AudioFileStream`パイプラインでのADTS復号**: 見送り。タスクの明示的な指示
  どおり、まず`AVPlayer`ルートを試すに留め、実機でAVPlayerが本当に再生できないと
  確認できるまでカスタムデマルチプレクサは実装しない。`TVRelayPlaybackController`を
  薄いシームとして切り出したのはこの判断のため——もし将来カスタムパイプラインが
  必要になっても、差し替えはこのファイルの内部のみで完結する設計にした。
- **`relayModel`のポーリング間隔をイベント駆動にする**: 見送り。ホストの
  `GET /v1/remote/state`は既存のRemote機能全体で単純ポーリング前提の設計になっており
  （`RemoteControlScreen`等）、TVの受信側だけWebSocket等のプッシュ通知を新設するのは
  スコープ過大と判断。5秒間隔のポーリングは他のRemote系ポーリングと同程度の頻度。

## Constraints / Gotchas

- **実機検証が必要な項目（このチケットのスコープ外・要フォローアップ）**:
  1. `AVPlayer`が、コンテナ無し・チャンク転送（`Content-Length`固定値なし）の生ADTS
     AAC-LC基本ストリームを実際に再生できるかどうか。HLS/fMP4のような正規のライブ
     ストリーミングコンテナではないため、`AVURLAssetOverrideMIMETypeKey`のヒントだけで
     `AVPlayer`が正しくデコード・再生を開始する保証はない。
  2. 生の文字列キー`"AVURLAssetHTTPHeaderFieldsKey"`がtvOSの`AVURLAsset`実装で
     実際にHTTPリクエストへ反映されるか（コンパイルは通るが、キー名の綴りやtvOSでの
     サポート状況はドキュメント化されていない）。
  3. 上記いずれかが機能しない場合の代替: (a) ホスト側にサーバー変更を依頼して
     `/v1/remote/relay`も`?token=`クエリを受け付けるようにする（別エージェント領域と
     交渉が必要）、または(b)本チケットで見送ったカスタム`AudioFileStream`/
     `AVSampleBufferAudioRenderer`ベースの再生パイプラインへ切り替える。
     いずれも`TVRelayPlaybackController`の内部実装のみの変更で収まるよう設計している。
- **サムネイルはホスト非依存**: `relay.thumbnail`はYouTube CDN上のURL（例:
  `i.ytimg.com`）で、LAN内のホストを経由しない。ホストがオフラインでもサムネイル自体は
  読み込める可能性がある点に注意（が、`isAvailable`がfalseになれば棚自体が消えるため
  実害はない）。
- **`TVRelayModel`のcapabilitiesキャッシュは再接続まで無効化されない**: TVアプリの
  1セッション中にホストのサーバーモードがGUI↔headless間で切り替わることは通常
  想定していない（`progress/serve-headless-mode.md`のモデル通り、`--serve`は別プロセス
  起動）。もし将来的にランタイムでモード切替が起きる設計になった場合はこのキャッシュを
  見直す必要がある。

## 追記: 「中継が失敗すると何も再生できなくなる」の修正（失敗検知とテアダウン）

実機フィードバックで報告された不具合: 中継（YouTube）再生が失敗すると、以降ローカル再生も
含めて何も再生できなくなる。

### 何が壊れていたか

- `TVRelayPlaybackController`は`start()`で`AVPlayerItem`/`AVPlayer`を作って`play()`を
  呼ぶだけで、**失敗を検知する仕組みが一切無かった**。生ADTSストリームが`AVPlayer`で
  デコードできない（本ファイル冒頭のコメントに記録済みの未検証リスク）場合、
  `AVPlayerItem.status`が`.failed`になっても誰も観測しておらず、コントローラは
  「再生中のつもり」のまま固まっていた。
- `TVBrowseView`側もこの失敗を知る手段が無いため、`TVRelayBannerView`は「読み込み中の
  ままのダミー動画」を表示し続け、ユーザーが手動で「終了」を押さない限りバナーが閉じず、
  ローカル`MusicPlayerService`の状態自体は`playRelay()`で`player.stop()`済みのため、
  実際にはローカル再生は「再開できる」状態だったが、**UIがバナーに閉じ込められたままで
  そこへ戻る手段が実質無かった**（実機のリモートで「終了」ボタンへフォーカスが渡らない/
  応答が遅い等、失敗した`AVPlayer`のパイプラインがUIスレッド近辺で詰まる報告と一致）。

### Decision（状態機械の分離とTDD）

- 純粋ロジックを`TVRelayPlaybackReducer`（新規 `TVRelayPlaybackReducer.swift`）に切り出し、
  `AVFoundation`に触れず単体テスト可能にした（`TVRelayPlaybackReducerTests.swift`）。
  - `TVRelayPlaybackState`: `.idle` / `.playing` / `.failed(reason:)`
  - `TVRelayPlaybackEvent`: `.start` / `.fail(reason:)` / `.exit`
  - `TVRelayPlaybackReducer.isLocalPlaybackUsable(_:)` — **本修正の核心の不変条件**:
    `.idle`と`.failed`は常に`true`、`.playing`のときだけ`false`。つまり「中継が失敗した
    状態」は「中継していない状態」と同じくローカル再生可能、という不変条件をテストで
    固定した（`testFullFailureRecoveryLifecycleEndsPlayerUsable`で
    start→fail→exitの一連の遷移を通しで検証）。
- `TVRelayPlaybackController`は3つの失敗シグナルを監視するようにした:
  1. `AVPlayerItem.status`のKVO監視 → `.failed`になったら`fail(reason:)`。
  2. `AVPlayerItemFailedToPlayToEndTimeNotification`の通知監視。
  3. 起動後8秒（`startupTimeout`、テスト時は差し替え可能）以内に`AVPlayer.rate`が
     一度も0超にならなければタイムアウトとして`fail(reason:)`（レート監視はKVOで
     `didStartPlaying`フラグを立てる）。
  - いずれかが発火すると`fail(reason:)`が呼ばれ、`teardown()`（KVO解除・通知解除・
    タイムアウトタスクキャンセル・`AVPlayer`停止＆破棄）を実行してから
    `state = .failed(reason:)`に遷移する。**テアダウンを先に行うため、失敗が検知された
    時点で既にローカル再生は使用可能な状態に戻っている。**
  - 二重failガード: `fail(reason:)`は`state == .playing`のときのみ有効
    （タイムアウトと`AVPlayerItem`失敗が同時に発火しても2回目は無視）。
- `TVRelayBannerView`は`relayPlaybackController.state`を見て、`.failed(reason:)`のときは
  再生中UIの代わりにエラーバナー（黄色い警告アイコン＋「中継の再生に失敗しました」＋理由＋
  「終了」ボタンのみ）を表示する。表示された時点で既にローカル再生は復旧済みなので、
  このビューは「ユーザーに知らせて閉じさせる」以上のことをする必要がない。

### Alternatives considered

- **バナー表示中に裏で自動的にバナーを閉じる（`relayPresented = false`を失敗検知時に
  自動セット）**: 見送り。ユーザーに「失敗した」ことを知らせずに黙って閉じると、
  「押したのに何も起きなかった」という別の混乱を生む。エラーの可視化を優先し、閉じるのは
  明示的な「終了」ボタン（既存の`onDisappear`経路）に統一した。
- **`AVPlayer`の失敗時に自動リトライ**: 見送り。ブリーフの要求は「ローカル再生への復帰」で
  あり、リトライは要求されていない上、根本原因（生ADTSが再生できない可能性）が解消しない
  限りリトライしても同じ結果になる可能性が高い。

### Constraints / Gotchas

- `AVPlayerItem`/`AVPlayer`のKVOオブザーバーとNotificationCenterオブザーバーの解除漏れは
  クラッシュ・メモリリークに直結するため、`teardown()`に一本化し、`stop()`（正常終了）と
  `fail(reason:)`（異常終了）の両方から必ずこの1箇所を通るようにした。
- `startupTimeout`をイニシャライザ引数化した（デフォルト8秒）ことで、将来テストで
  `AVPlayer`をモック化する際にタイムアウトを短く差し替えられる余地を残した
  （今回は`AVFoundation`実体を使うテストまでは書いていない——`TVRelayPlaybackReducer`側の
  純粋ロジックのみTDD対象とし、`AVPlayer`配線自体は実機/シミュレータでのビルド・
  目視確認に留めた）。

## 追記（AVPlayer不可の確定・自前ADTS再生への置き換え）

### Decision

- **実機でAVPlayerが生ADTS中継ストリームを再生できないことが確定した。** `GET
  /v1/remote/relay`はコンテナなしのチャンクADTS AAC-LCエレメンタリストリームであり、
  `AVURLAsset`が再生可能アイテムとして解決できず、単なる「失敗しうる」ではなく一貫した
  ハード失敗だった（既存の失敗検知・ローカル復旧経路自体は正しく機能することを確認済み）。
- `TVRelayPlaybackController`のAVPlayer経路を、自前実装の`TVRelayStreamPlayer`に置き換えた。
  構成: `URLSession`ストリーミングdata task（`Authorization: Bearer`ヘッダ付き）→
  `ADTSFrameParser`（純粋な増分バイト列パーサ、`UX-Music-Mobile/Services/`に配置し
  iOS側も将来共有可能）→ `TVAACDecoder`（`AVAudioConverter`でADTSフレームをPCM Float32に
  デコード）→ 約0.75秒のジッタバッファ → 専用`AVAudioEngine`/`AVAudioPlayerNode`で
  スケジュール再生。
- **エンジン選択**: `MusicPlayerService`のエンジンを再利用せず、専用の軽量`AVAudioEngine`を
  都度起動・破棄する方式を採った。`TVRelayPlaybackController`は中継開始前に呼び出し側が
  ローカル再生を停止している前提のため、エンジンの排他制御を新たに設計する必要がなく、
  10バンドEQ・LUFS正規化グラフ（中継ストリームは既にホスト側でミックス済みの音声なので
  不要）に無関係なサブシステムを結合する理由もない。単純さを優先した。
- **ジッタバッファ**: 0.75秒分のPCMがバッファされてから`playerNode.play()`を呼ぶことで、
  チャンク転送のネットワーク揺らぎを吸収する。「起動成功」の判定基準もAVPlayerの
  `rate`監視から「PCMが実際にスケジュールされ始めたか」に変更した（8秒タイムアウト・
  失敗バナー・ローカル再生復旧という既存の状態遷移自体はそのまま維持）。
- **DEBUGログ信号**: `TVRelayStreamPlayer`は約2秒ごとに`[RelayStream] rendering rms=<value>`
  をNSLog出力する（DEBUGビルドのみ）。実機・シミュレータでの検証や将来のデバッグに使う。

### TDDフィクスチャ

- 実際に中継ストリームをキャプチャした`relay-sample.aac`（約6秒、ADTS AAC-LC、
  256kbps/44.1kHz/stereo）を`UX-Music-TVTests/Fixtures/`にコミットし、
  `ADTSFrameParserTests`（1バイトずつ・任意境界でのチャンク分割・ゴミバイト混入からの
  再同期を含む）と`TVAACDecoderTests`（デコード後PCMのRMSが無音でないことを検証）で
  このサンプルに対してTDDした。tvOSシミュレータのテストスイートは全件green。

### シミュレータE2E検証

- 実ホストなしで検証するため、`relay_sample.bin`を`/v1/remote/relay`としてチャンク転送
  （約32kB/sペーシングでループ配信）する使い捨てのPython製モックHTTPサーバーを用意した。
- `UXMusicTVApp`に`UXTV_PREVIEW=relay`ハーネス（`TVRelayStreamPreviewHarness`）を追加し、
  `UXTV_RELAY_HOST`/`UXTV_RELAY_PORT`/`UXTV_RELAY_TOKEN`環境変数（`simctl launch`実行前に
  呼び出し元シェルで`SIMCTL_CHILD_`プレフィックス付きでexportする必要がある——
  `simctl launch <device> <bundle-id> <argv...>`の末尾引数として渡してもプロセス環境には
  伝播しない）でモックサーバーへ接続し、ペアリングUIなしで`TVRelayPlaybackController.start()`
  を即座に呼ぶ。
- 検証中に2つの実行時クラッシュを発見・修正した（詳細はコミットログ参照）:
  1. `AVAudioEngine.connect(playerNode, to: mainMixerNode, format: nil)`を`start()`時点
     （デコード形式判明前）に呼んでいたため、ノードのデフォルト出力フォーマットと
     実際にスケジュールするPCMのフォーマットが食い違い、`AURemoteIO`のレンダースレッドで
     `EXC_BAD_ACCESS`を起こしていた → 最初のフレームをデコードして実フォーマットが
     判明してから遅延接続するように変更。
  2. 接続フォーマットに`interleaved: true`を使っていたため
     `kAudioUnitErr_FormatNotSupported(-10868)`で例外終了していた →
     `AVAudioEngine`の内部グラフはnon-interleaved（canonical）フォーマットを要求するため
     `TVAACDecoder.outputFormat`を`interleaved: false`に変更。
- 修正後、`xcrun simctl spawn ... log stream`で`[RelayStream] rendering rms=0.08〜0.15`
  （無音でない値）が約2秒間隔で25秒以上継続することを確認した。モックサーバーはこの後
  停止済み（使い捨て、リポジトリには含まれない）。

### 残課題

- **実機での音出し確認は未実施。** シミュレータのCoreAudioスタックと実機のtvOS
  デバイスのオーディオ経路は完全に同一ではないため、実Apple TV実機で実際にホストの
  中継ストリームに接続し、耳で聞こえることの確認が残っている。
- ネットワーク切断時の再接続は本フェーズのスコープ外（要求どおり）——ホスト側の停止や
  切断は既存の失敗検知経路（ネットワークエラー→`fail(reason:)`→ローカル再生復旧）に
  乗るのみで、自動再接続はしない。
- ジッタバッファ長（0.75秒）やチャンクごとのデコード粒度（1024サンプル/ADTSフレーム）は
  実機のWi-Fi環境でのネットワーク揺らぎに対するチューニングをまだ行っていない。

## 追記（2026-08-13）: TVでのYouTube曲選択→PC経由再生→中継自動参加

対象: `UX-Music-Mobile/`のみ。デスクトップ側の`POST /v1/remote/command`（`action:
"play-song"`）は既に別エージェントが実装・マージ済み（`progress/remote-play-song.md`
参照）。ここではTVがそれを叩いて中継に自動参加するところまでを実装した。

### Decision

- **選曲ルーティングの判別軸**: `Song.isYouTube`（`sourceType == .youtube`、iOS/Mobile側の
  `rowTapAction(isDownloaded:)`が既にYouTube由来かどうかの判定に使っている同じフィールド）
  をそのまま流用した。TV独自の判定ロジックは作らず、`TVSongPlaybackRouting.route(for:)`
  という1行の純粋関数（`song.isYouTube ? .viaPC : .local`）に切り出しただけ。ローカル曲は
  既存の`TVPlaybackController.play(_:queue:)`経路を一切変更していない。

- **待機フローの状態機械**: `TVRemotePlaySongReducer`（`idle → sending → waitingForRelay →
  active` / `failed(reason:)`）を`TVRelayPlaybackReducer`と同じ設計パターンで新設し、
  ネットワーク副作用を`TVRemotePlaySongCoordinator`（`ObservableObject`）に分離した。
  Coordinatorは`RemoteAPIClient.sendPlaySongCommand(songId:)`を叩き、成功後は
  `GET /v1/remote/state`を0.5秒間隔・最大10秒ポーリングして`relay.active`を待つ
  （`TVRelayStateBlock.parse`を再利用——中継可否棚の判定と同じパース関数）。`active`を
  観測したら`TVRelayPlaybackController.start()`を呼んで既存の中継受信（`TVRelayStreamPlayer`
  経由のADTS AAC-LC再生）にそのまま合流させる——新しい受信パスは作っていない。

- **UI統合**: `TVBrowseView.play(_:queue:)`の入口を`TVSongPlaybackRouting.route(for:)`で
  分岐。`.viaPC`側は`player.stop()`→`remotePlaySongCoordinator.start(songId:)`→
  `TVBrowsePresentation.remotePlaySong`（新設の待機/エラー画面）を表示し、
  `remotePlaySongCoordinator.state`が`.active`になったら`presentation = .relay`へスワップして
  既存の`TVRelayBannerView`（ブロードキャスト型・操作なし）に着地する。失敗
  （`gui_required`・404・タイムアウト）は`TVRelayBannerView`の失敗表示と同じ見た目
  （アイコン＋理由文＋「終了」ボタン）で待機画面自身が表示し、ボタンで
  `fullScreenCover`を閉じて元の画面（ブラウズ棚 or 詳細トラック一覧）に戻る。
  `RemoteAPIClient.sendPlaySongCommand`は`sendCommand(action:value:)`と違い`Bool`ではなく
  `throws`にした——`gui_required`（409）・未知の曲（404）・単純なネットワーク失敗を
  呼び出し側で区別してローカライズ文言を出し分ける必要があるため。

- **視覚マーカーの配置範囲**: 「YouTube由来の曲はPC経由で再生される」ことを示す
  `TVRemotePlayBadge`（小さな「PC」ピル、`TVDesignTokens.signaturePink`基調）は
  `TVLibraryDetailView`のトラック行（`TVTrackRow`）にのみ追加した。ブラウズ棚は現状
  アルバム/プレイリスト単位（`Album.fromSongs`によるグルーピング）で、個々の曲を直接
  並べる棚が存在しないため、「棚に出す」対象がそもそも無い。将来単曲棚が追加された場合は
  同じ`TVRemotePlayBadge`を再利用する想定。

### Alternatives considered

- **`"remote-command"`と同様に`sendCommand(action:value:)`を`Bool`のまま拡張し`songId`も
  渡せるようにする** → 呼び出し側（TVのPC経由再生フロー）が失敗理由（`gui_required`か
  ただのネットワーク断か）を区別できず、ローカライズ文言を出し分けられないため不採用。
  専用の`sendPlaySongCommand(songId:) async throws`を新設した。
- **待機UIを`TVRelayBannerView`に状態を追加してそのまま流用する** → 「PCへの送信中／
  中継が上がるのを待っている」という、既存の`TVRelayPlaybackState`にはない中間状態が
  必要になり、既存の型を汚さず`TVRemotePlaySongState`を独立させた方が
  `TVRelayPlaybackReducer`のテストの意味も曇らせずに済むと判断した。UIの見た目
  （アイコン・ボタン配置）はあえて`TVRelayBannerView`の失敗表示に揃えている。

### Constraints / Gotchas

- ポーリング間隔0.5秒・タイムアウト10秒は`TVRemotePlaySongCoordinator`のイニシャライザ
  引数として注入可能にしてある（`TVRelayModel.startPolling(interval:)`と同じ設計）。
  実機でのチューニングが必要になった場合はここを調整する。
- TDD対象は`TVSongPlaybackRouting.route(for:)`と`TVRemotePlaySongReducer`の純粋部分のみ
  （`UX-Music-TVTests/TVRemotePlaySongFlowTests.swift`）。`TVRemotePlaySongCoordinator`自体
  （ネットワーク・ポーリングの副作用）はユニットテストしていない——実ホストを立てずに
  検証する指示だったため、UI差し込み（`TVBrowseView`の分岐）と状態遷移ロジックの正しさで
  担保する方針とした。
- UI確認は`UXTV_PREVIEW=youtubebadge`（新設）で、ローカル曲とYouTube曲混在の詳細画面を
  ペアリング/ネットワーク無しでスクリーンショットできる。他のプレビューモード
  （`nowplaying`/`browse`/`albumdetail`/`detailplay`/`relay`）と同じ仕組み。

## 追記（ファイル有無で分岐・PC経由再生の透明化・Now Playing初回アートワーク欠落）

実機（`127.0.0.1:8765`）を読み取り専用で確認したところ、ライブラリ中のYouTube由来曲の
大半は既にダウンロード済みで、ホストが`/v1/remote/file/{id}`から直接音声を返せる
（`HTTP 206`確認済み）状態だった。にもかかわらずTVは`Song.isYouTube`だけで全件を
PC経由リレーへ回していたため、実際には再生できる曲までPCオペレーター依存のブロード
キャスト型再生に落としていた——「YouTube由来／ローカルの壁を作らない」という方針に反する。

### Decision

- **選曲ルーティングの判別軸を`Song.isYouTube`から`Song.hasLocalAudio`へ差し替えた**。
  `GET /v1/remote/songs`に並行して追加された加法的フィールド`hasLocalAudio: Bool?`
  （デスクトップ側が`/v1/remote/file/{id}`で実際に音声を返せるかを表す）を`Song`に追加し、
  欠落時は`nil`のまま保持して`effectiveHasLocalAudio`（`hasLocalAudio ?? true`）で
  「missing → true」の後方互換を取った——欠落を「音声なし」と誤読すると、旧デスクトップや
  ロールアウト中の応答に対して全曲がPC経由に落ちてしまうため。
  `TVSongPlaybackRouting.route(for:)`は`song.effectiveHasLocalAudio ? .local : .viaPC`の
  1行に置き換え、`.local`側は既存の`TVPlaybackController.play(_:queue:)`経路
  （EQ/LUFS・フルトランスポート・prefetch/cache・play-event報告）を一切変更していない。
  「PC」バッジ（`TVRemotePlayBadge`）も表示条件を`song.isYouTube`から
  `TVSongPlaybackRouting.route(for:) == .viaPC`へ変更し、実際にPC経由でしか再生できない
  曲にのみ出るようにした。
- **リレーバナーへ最小限のトランスポート（再生/一時停止・停止）を追加した**。従来は
  「PCオペレーターが操作する放送」という設計で終了ボタンしか無く、選曲後にTVから
  一切制御できなかった。`TVRelayBannerView`に`POST /v1/remote/command`
  （`action: "toggle"`/`"stop"`）を送るボタン2つを追加し、Siri Remoteの物理再生/一時停止
  ボタンも`.onPlayPauseCommand`で同じ`toggle`にマッピングした。次/前スキップは追加して
  いない——デスクトップのYouTube embed再生にはキュー概念が無く、`next`/`prev`を送っても
  意味のある挙動にならないため（`server/app_remote.go`の`remoteCommandHandler`は
  `toggle`/`play`/`pause`/`stop`/`next`/`prev`/`seek`/`play-song`を受け付けるが、embed
  再生中の`next`/`prev`の扱いはデスクトップ側の並行修正の範囲）。再生/一時停止状態は
  `GET /v1/remote/state`のルート直下`playing`キー（`server/app_audio.go`の
  `AudioGetStatus`）を`TVRelayModel`が既存の5秒ポーリングで追加取得し
  （純粋パース部分は`TVRelayTransportState.isPlaying(fromStateJSON:defaultingTo:)`に
  切り出してTDD）、`isPlaying`として公開している。停止ボタンは`stop`コマンド送信後に
  `onExit()`を呼び、既存の離脱経路（`dismiss` → `onDisappear` →
  `relayPlaybackController.stop()`）でTV側の中継受信を確実にteardownする。
  デスクトップがembed再生中に`toggle`/`stop`を実際に honour するかは並行して進んでいる
  デスクトップ側修正の範囲——この変更の責務は「正しいコマンドを送り、次の
  `/v1/remote/state`ポーリングで状態を反映する」ところまで。
- **Now Playing初回オープン時のアートワーク欠落を修正した**。原因は`TVArtworkImage`が
  素の`AsyncImage(url:)`に依存していたこと：`AsyncImage`は自身の内部`onAppear`から
  フェッチを開始するが、`.fullScreenCover`の提示トランジションの最中に新規挿入される
  ケースでは、その内部`onAppear`の発火がトランジションとレースして取得が始まらない/
  取りこぼされることがあり、しかも`AsyncImage`はURLが変わらない限り自動リトライしない
  ——一度崩れると同じNow Playingセッション中は復帰しない。2回目に開くときは
  トランジション外で`TVNowPlayingView`/`TVArtworkImage`が新規に構築されるため問題なく
  読み込め、「初回だけ欠ける・開き直すと直る」という報告と一致する。修正は
  `TVArtworkImage`を`AsyncImage`から`.task(id: artworkId)`駆動の自前ローダー
  （`RemoteLANURLSession.shared`で取得し`@State private var loadedImage: UIImage?`に
  格納、プレースホルダー→フェードイン）へ置き換えた。`.task(id:)`のライフサイクルは
  提示トランジションのappear/disappearタイミングとは独立してスケジュールされ、
  `artworkId`ごとに一度だけ確実に実行される。実機（`127.0.0.1:8765`）に対して
  `UXTV_PREVIEW=livenowplaying`ハーネス（既存、`MusicPlayerService.masterVolume = 0`で
  無音化済み）でTVシミュレータ起動直後にNow Playingを初回表示させ、アートワークが
  即座に表示されることをスクリーンショットで確認した
  （`/tmp/claude-501/.../scratchpad/tvfix_artwork_first.png`）。

### Alternatives considered

- **アートワーク欠落をURLCacheのウォームアップやリトライロジックの追加で対処する** →
  根本原因が「トランジション中のAsyncImage内部`onAppear`のレース」である以上、対症療法
  になりがちで再発リスクが残る。`.task(id:)`への置き換えは`AsyncImage`の暗黙のライフ
  サイクルそのものを回避できるため、より確実な修正と判断した。
- **リレーバナーに次/前スキップも追加する** → デスクトップのYouTube embed再生には
  キュー・プレイリストの概念が無く、`next`/`prev`を送っても現状は意味のある挙動を
  定義できないため見送った。デスクトップ側にキュー機能が入った場合の拡張ポイントとして
  `TVRemoteCommandHandler`側の語彙（`next`/`previous`）は既に存在する。

### Constraints / Gotchas

- `hasLocalAudio`はデスクトップ側の並行修正（`GET /v1/remote/songs`への追加）が前提。
  本変更はデコード側（`Song.hasLocalAudio: Bool?` + `effectiveHasLocalAudio`）と
  ルーティング側（`TVSongPlaybackRouting`）のみで、フィールドが未着地の期間も
  「欠落→true→ローカル扱い」で安全に動作する。
- リレーバナーのトランスポート状態は`TVRelayModel`の5秒ポーリング間隔に依存するため、
  トグル直後の見た目の反映に最大5秒のラグがありうる。実機でユーザー体験上問題になる
  場合はリレーバナー表示中だけポーリング間隔を短縮する改善余地がある（未実施）。
- リレーバナーのトランスポートボタンの実機E2E（実際にホストのembed再生をtoggle/stopで
  操作できるか）は、ホストへの書き込み系操作（`POST`）が本タスクの制約で禁止されて
  いたため未検証——TV側が正しいリクエストを送ることと、`TVRelayModel`のポーリングが
  正しく状態を反映することは単体テスト/ビルドで確認済み。デスクトップ側のembed再生が
  実際に`toggle`/`stop`を honour するかは並行するデスクトップ側修正の検証範囲。

## 追記（2026-08-13）: Task B — リレーバナーへのシークバー追加

### Decision

- `GET /v1/remote/state`ルート直下の`position`/`duration`（デスクトップ側で並行拡張中）を
  純粋パースする`TVRelayPositionState`を新設（既存の`TVRelayStateBlock`/
  `TVRelayTransportState`と同じ「欠落・不正値は安全側に倒す」方針を踏襲）。
  `duration`が欠落・0以下なら`isSeekable == false`とし、`TVRelayBannerView`側は
  そのままバーを隠す（ブリーフの「absent/zero durationを優雅に扱う」要件）。
- シーク送信は既存の`RemoteAPIClient.sendCommand(action:value:)`をそのまま使用——
  `server/app_remote.go`のseekケースを実際に読み、フィールド名が`"value"`（float64、
  `sendCommand`の`value`引数と同名）であることを確認した上で配線した。
- **楽観的UI**: `TVRelayModel.seek(to:)`は`POST`を投げると同時に`position`を即座に
  シーク先へ更新する。ブリーフに明記されている通り、ジッタバッファ（`TVRelayStreamPlayer`の
  0.75秘バッファ）越しに実際の音声がジャンプするまで約1秒かかるため、ポーリング結果
  （5秒間隔）を待つとバーの操作感が著しく悪くなる。ポーリングが返す位置が楽観値の2秒
  以内に追いついたら楽観値を破棄して信頼するポーリング値に戻す、というシンプルな収束
  条件にした。
- tvOSイディオム: シークバー自体を`.focusable(true)`にし、フォーカス中は`onMoveCommand`の
  `.left`/`.right`で±10秒（押しっぱなしはシステムのリピート挙動に委譲——追加のタイマー
  実装はしていない）。トランスポート行にも同じ±10秒ボタンを追加し、両方から同じ
  `TVRelayPositionState.seekTarget(delta:)`（0...durationにクランプ）を呼ぶ。

### Constraints / Gotchas

- デスクトップ側の`position`/`duration`拡張が未着地の間は`isSeekable`が常に`false`となり
  バーは表示されない——追加的な変更なので古いホストに対しても安全に劣化する。
- 実機/実ホストでの「シーク送信→実際に約1秒後に音声がジャンプする」E2Eは、本タスクの
  制約（ホストへの書き込み系`POST`実行が原則禁止）のため未検証。TV側の純粋ロジックと
  リクエスト構築は単体テストで確認済み。

## 追記（2026-08-13）: コーディネーター追加スコープ — トランスポートフォーカスの
レイアウトシフト修正・リレーサムネイルの16:9表示

### Decision

- **レイアウトシフト**: 根本原因はユーザー報告どおり`TVTransportButtonStyle`の
  `.font(weight: isFocused ? .semibold : .regular)`——グリフの実サイズ（intrinsic size）が
  フォーカスの有無で変わり、`HStack`内の兄弟要素（アートワーク等）が再レイアウトされて
  いた。修正はフォーカス時の最大サイズ（`size * 1.22`スケール分 + パディング）で
  `.frame(width:height:)`を固定し、それより後段の`scaleEffect`（描画のみ・レイアウト
  非関与）で見た目の拡大を行う方式に統一。これにより中身（ウェイト・色・グロー）が
  変化してもレイアウトへの寄与は常に一定になる。
- **リレーサムネイル16:9表示**: YouTubeサムネイルは16:9であり、既存の正方形アートワーク
  フレームにそのまま押し込むと不自然なクロップが発生する。16:9の専用カード
  （`relayThumbnailCard`）を新設し、同じ画像をぼかして敷いたレターボックス背景＋
  シャープな前面画像のフェードインというシネマティックな言語を維持したまま実装した。

### Constraints / Gotchas

- レイアウトシフト修正の実機/シミュレータでのフォーカス⇄非フォーカス比較スクリーンショット
  検証は部分的にしか実施できなかった。`UXTV_PREVIEW=detailplay`ハーネスで
  トランスポートバー（`TVNowPlayingTransportBar`、`TVTransportButtonStyle`使用）を
  1枚スクリーンショット取得——デフォルトで再生/一時停止ボタンにフォーカスが当たった
  状態（拡大・白発光）を確認できたが、そこから他のボタンへフォーカスを移す
  キー入力操作（computer-use MCP経由のSimulatorへのキー送信）が本セッション環境で
  "user interrupt"エラーを繰り返し返し実行できず、フォーカス移動前後の2枚比較は
  未完了。修正自体はコードレビュー（固定`.frame(width:height:)`の適用箇所の確認）と
  ビルド成功で担保している——次回、tvOSシミュレータへの確実なキー入力手段が使える
  環境で2枚比較を追記する。
- サムネイルのフェードインは`AsyncImage`の`.transition(.opacity)`に依存しており、
  `progress/tvos-design.md`で既知の「トランジション中の`AsyncImage`内部`onAppear`レース」
  と同種の潜在リスクがある——現時点では顕在化を確認できていないが、アートワーク欠落系の
  不具合が再発した場合はまずこのパスを疑うこと。
