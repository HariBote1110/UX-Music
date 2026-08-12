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
