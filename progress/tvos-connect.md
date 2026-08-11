# TVをConnect型の再生ターゲットにする・再生完了報告（Phase 3-1/3-2 クライアント側）

対象: `UX-Music-Mobile/` のみ（`server/`等Goサイドは対象外・並走エージェントの担当）。

## Decision

- **既知ギャップの解消（プレイリスト棚のタップ再生）**: `progress/tvos-nowplaying.md`に記録済みの
  「プレイリスト棚はタップ操作を持たない」を解消。`RemoteDesktopPlaylist`は`songIds`のみを
  持つため、純粋関数`TVPlaylistQueueBuilder.songs(for:allSongs:)`で`TVBrowseModel`が既に
  取得済みの`[Song]`へ解決し、アルバム棚と同じ`play-from-first`＋Now Playing自動遷移の
  経路（`TVPlaybackController.play(_:queue:)`→`nowPlayingPresented = true`）に接続した。
  存在しないIDは無視（サイレントスキップ、`pathsNotInLibrary`と同じ扱い）。

- **再生完了報告（3-2）**: `MusicPlayerService`に`onTrackNaturallyFinished: ((Song) -> Void)?`
  フックを追加し、`advanceAfterEnd()`（バッファ完了/YouTube `.ended`経由の自然終了のみ。
  `next()`/`previous()`の明示スキップでは発火しない）の先頭で呼ぶ。TV側はこれを
  `TVPlayEventReporter`で受け、`RemoteAPIClient.postPlayEvent`（新設）経由で
  `POST /v1/remote/play-event`へ`{"trackId","playedAt","durationPlayedSec"}`を送信する。
  - 「報告するか」の判定（`TVPlayEventPolicy.shouldReport`）と`playedAt`のRFC3339整形
    （`TVPlayEventPolicy.rfc3339`、UTC・小数秒あり）は純粋関数としてTDD。
  - **再生カウント方針**: `onTrackNaturallyFinished`が発火する時点で既に「自然終了」が
    確定しているため、クライアント側の判定は「本当に報告に値するデータか」（`song.id`が
    空でない・`duration > 0`）のみに限定した。完了/未完了の判定自体はコールバックの
    発火経路（`advanceAfterEnd`かどうか）で既に行われている。サーバー側の
    `isCountedPlay = Completed || DurationPlayedMs >= 30000`（`progress/remote-play-event.md`）
    とも整合する。
  - **失敗時の扱い**: `TVPlayEventReporter.report`はfire-and-forget（`Task.detached`）。
    1回失敗したら1回だけ即座にリトライし、それでも失敗すれば`Logger`にエラーを残すのみで
    再生を止めない。サーバー側の`eventId`が`deviceId+trackId+playedAt`から決定的に導出される
    冪等設計（`progress/remote-play-event.md`）のため、リトライで二重カウントは起きない。

- **TVの受け口（3-1 TV側）**: `TVRemoteControlServer`（`Network.framework`の
  `NWListener`/`NWConnection`）が固定ポート**8766**（8765=デスクトップLAN APIと衝突しない値）で
  HTTP/1.1を最小限に自前実装し、以下を提供する。
  - `GET /v1/identity`（認証不要・`roles: ["tv"]`固定）
  - `GET /v1/remote/state`（認証必須。`position`/`duration`/`playing`/`paused`/`title`/
    `artist`/`album`はデスクトップの`remoteStateHandler`と同じキー、`volume`はTV独自追加）
  - `POST /v1/remote/command`（認証必須。`toggle`/`play`/`pause`/`next`/`prev`/`previous`/
    `seek`（要`value`）に対応。デスクトップの語彙（`server/app_remote.go`の
    `remoteCommandHandler`）にそのまま揃え、`volume`（要`value`）のみTV独自で追加——
    `MusicPlayerService.masterVolume`はTVに存在するがデスクトップの語彙には無いため）。
    未対応actionは`400`＋`{"ok":false,"error":"unsupported action: <name>"}`で
    ドキュメント化されたエラーを返す（無視やクラッシュはしない）。
  - 認証・アクション解決・state整形（`TVRemoteCommandHandler.swift`）とHTTPフレーミング
    （`TVRemoteHTTPMessage.swift`のリクエストパース/レスポンス生成）は全て純粋関数として
    TDD。ソケット層（`TVRemoteControlServer`）はそれらへの薄い配線のみで、直接のユニット
    テストは持たない（Networkフレームワークの実ソケットが絡むため）。

- **認証: 対称共有シークレット**: 受け口は「TVがペアリング時にHostから取得した既存トークン」
  とのBearer一致を要求する（`TVServerConfigStore`が既に永続化しているものをそのまま使う。
  TV専用の別トークンを新規発行しない）。iOS側がこのトークンを知る手段が既存のどの経路にも
  無いため、`TVRemoteControlServer`が自己広告するmDNS TXTレコードに`token`フィールドとして
  含めることにした。
  - **これは`progress/tvos-pairing.md`実装時の既存結論の延長**: 同ドキュメントは
    「`/v1/pairing/*`の安全境界はLAN上で到達できること自体」と結論し、ホスト側の人手承認を
    要求しない設計を採っている。TVの受け口トークンをmDNS TXTで広告することも同じ境界
    （LANに参加できる端末は既に信頼されている）の上に立つ判断であり、新しい種類の露出を
    増やすものではないと判断した。
  - 一方、既存の`_uxmusic-sync._tcp`のTXTレコード（`internal/uxsync/mdns.go`）は
    `deviceId`/`displayName`/`protocolVersion`/`schemaVersion`/`roles`のみで、シークレットを
    含めない設計になっている。**今回の`_uxmusic-remote._tcp`はこの既存の無害化方針から
    意図的に外れる**判断であり、理由は「TVの受け口が制御できるのはTV自身の再生のみ
    （ライブラリ本体へのアクセス権は無い）」という被害範囲の限定にある。ライブラリ全体を
    晒す`/v1/sync/*`用の認証情報とは非対称なリスクだと考えている。

- **mDNSサービスタイプ**: `_uxmusic-remote._tcp`（新設、既存の`_uxmusic-sync._tcp`とは別）。
  TVはSyncピアではない（`markdown/appletv-servermode-plan.md`の明文化事項3）ため、
  Sync発見の語彙に混ぜない。

- **iOS側ターゲットピッカー（3-1 Mobile側）**: `RemoteControlScreen`に
  `RemoteControlTargetPicker`（メニュー形式、「この iPhone」／発見済みTV一覧）を追加。
  `TVRemoteDiscoveryService`（`NetServiceBrowser`、`_uxmusic-remote._tcp`を探索）で
  `TVRemoteTarget`（host/port/token）を収集し、選択がTVのときは
  `model.withFailover`（Host用・複数候補フェイルオーバー付き）を経由せず、
  `RemoteAPIClient(baseURLString: target.baseURLString, token: target.token)`を都度組んで
  `sendCommand`/`fetchState`を直接呼ぶ。既存のRemoteタブのコマンド送信コード
  （`RemoteAPIClient`の同じメソッド群）をそのまま再利用し、ベースURLとトークンだけが
  差し替わる形にした。
  - ピッカー状態（`selectedTarget`）は`@State`のみ・永続化しない（タブを離れれば
    「この iPhone」に戻る）。
  - **デスクトップGUI側のピッカー（Wails版でTVを再生先として選ぶUI）は明示的にスコープ外**。
    本チケットはMobile側クライアントのみを対象とする。

## Alternatives considered

- **TVトークンをHost経由の新規APIで配布する**（例: `GET /v1/remote/tv-token`のような
  仲介エンドポイント）: 見送り。Goサーバーは並走する別エージェントの担当領域であり、
  新規サーバーエンドポイントの追加はスコープ外。mDNS TXT配布はサーバー変更なしで実現できる。
- **TVごとに新しい認証トークンを発行**: 見送り。`progress/remote-play-event.md`が3-2の
  play-event報告について既に下した判断（TV専用deviceIdを発行しない・既存の仕組みに
  乗せる）と一貫させ、3-1でも「TVは自分がペアリング済みの1個のトークンだけを持つ」
  という単純な形を維持した。
- **HTTPサーバーの実装にサードパーティライブラリを使う**: 見送り。このプロジェクトには
  パッケージマネージャー経由の依存関係が導入されておらず、`Network.framework`だけで
  必要最小限のHTTP/1.1（GET/POST、ヘッダ、`Content-Length`ボディ）を実装する方が
  依存追加より単純と判断した。
- **`LANDiscoveryService`を拡張してTV探索も担わせる**: 見送り。`LANDiscoveryPeer.
  supportsRemoteAPI`が`libraryHost`/`wearHost`ロール前提のゲートを持っており、
  `roles: ["tv"]`のTVはここを通過できない。ゲート条件を分岐させるより、
  `TVRemoteDiscoveryService`として素直に分離した方が既存コードへの影響が小さいと判断。

## Constraints / Gotchas

- **ポート8766はTVアプリのプロセス内でのみ有効**: `TVConnectedView`の`body`が表示されている
  間のみ`.task { remoteControlServer.start() }`／`.onDisappear { remoteControlServer.stop() }`
  でライフサイクル管理している。アプリがバックグラウンドに回った場合の継続動作は
  tvOSのバックグラウンド実行制約に従う（本チケットでは特別な対策をしていない）。
- **HTTPパーサーは`Content-Length`のみ対応**（chunked転送非対応）。iOS側の
  `RemoteAPIClient.sendCommand`/`fetchState`は常に`Content-Length`付きの小さなJSONしか
  送らないため実用上問題はないが、汎用HTTPクライアントからの接続は保証しない。
- **`volume`アクションはデスクトップの語彙に存在しない**: デスクトップの音量はホスト
  ローカルの操作でリモート化されていない。TVは`MusicPlayerService.masterVolume`を持つため
  追加したが、iOS側の既存コマンド送信コードは`volume`を送らない（Remote画面に音量スライダーが
  無いため）。将来iOS側にTV向け音量UIを足す場合はこのactionがそのまま使える。
- **ピッカーの「発見済みTV」リストは`RemoteControlScreen`表示中のみ**: `onAppear`/
  `onDisappear`で`TVRemoteDiscoveryService.start()`/`stop()`しており、タブを離れると
  探索も止まる（バッテリ配慮、既存の`LANDiscoveryService`の使われ方と同じ発想）。
