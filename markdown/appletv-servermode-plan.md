# Apple TV 対応・PC サーバー運用化 計画書

作成: 2026-08-11 ／ ステータス: **Phase 0〜3 実装完了（2026-08-12）— 実機検証待ち**
実機検証の残項目: 実タップ音声の E2E とレイテンシ・同一 WebKit ヘルパーへの二重タップ実負荷・出力デバイス切替時の relay タップ再構築（未実装ギャップ）・AVPlayer での生 ADTS 受信可否・TV/iPhone 実機動作・launchd 常駐の実運用投入（各 progress/ 記録の未確定リスト参照）
関連: `progress/lan-api-v1.md`（LAN API v1 SSoT）、`markdown/archive/sync-*.md`（Sync 各計画・アーカイブ済み）

## 0. ゴールと全体像

**ゴール = Phase 3 完了**: Apple TV が「常時 LAN 内の据え置きストリーミング端末」として、
(1) 10-foot UI での閲覧・再生、(2) 大画面 Now Playing（同期歌詞・アンビエント）、
(3) iPhone/デスクトップから選べる再生ターゲット（Connect 型）＋ YouTube 中継受信、
の 3 役をすべて果たし、その土台として PC がヘッドレス常駐サーバーとして運用できている状態。

```
Mac mini (Library Host)                    クライアント群
┌─────────────────────────────┐
│ uxmusic（単一バイナリ）        │   /v1/remote  ┌─ iPhone (UX-Music-Mobile)
│  ├ GUI モード（全部入り）      │◀─────────────┼─ Apple Watch (watchOS target)
│  └ --serve モード（常駐）      │               └─ Apple TV (tvOS target) ★新規
│    launchd LaunchAgent        │   /v1/sync ─── 他デスクトップ (MacBook / Crescent)
└─────────────────────────────┘
```

### 確定済みの大方針（再掲・変更しない）

- **GUI とサーバーは分離しない。単一バイナリ**で GUI モードと `--serve` ヘッドレスモードを切り替える。別デーモン案は不採用。
- **TV は Sync ピアにしない・ダウンロードしない**。Host からのストリーミング専用（tvOS はローカルストレージの恒久性が保証されないため）。
- **YouTube は公式 embed のみ**（グレー抽出は使わない）。PC の公式再生音声（Core Audio プロセスタップ済み）を LAN 中継する**放送型**。クライアントごとの別動画再生はしない（許容済み）。中継は音声＋メタデータのみで映像は PC 画面のみ。
- tvOS にはブラウザ・WebView が存在しないため、TV の YouTube は中継受信が本線。公式 YouTube アプリへのハンドオフ（スキーム起動）は実現可否を検証の上で「おまけ」として載せる。
- visionOS は対象外。

---

## Phase 0 — PC 基盤: ヘッドレス安全化とサーバー常駐

**目的**: GUI なしでもホスト機能が完全に動く状態を作り、launchd で常駐運用する。

### 0-1. wailsRuntime 結合の抽象化

- `server` パッケージの `wailsRuntime.EventsEmit` 全 51 箇所を `a.emit(name, data)` に集約する。
  既存の `playCountsEmitter`（関数注入）パターンの一般化。GUI モードでは Wails の
  EventsEmit、ヘッドレスモードでは no-op（将来 SSE ブリッジに差し替え可能な形）。
- ダイアログ系（`OpenDirectoryDialog` 等、計 16 箇所）を `DialogProvider` インターフェースの
  裏に隠す。ヘッドレス時はエラー返却（「GUI が必要な操作」を API エラーコードで表現）。
- 受け入れ基準: `server` パッケージから `wailsRuntime` の import が `app.go` の
  アダプタ実装 1 箇所（GUI モード用）だけになる。

### 0-2. `--serve` モードの完全化（`--sync-serve` の後継）

ヘッドレスで起動するもの:

| 起動する | 起動しない（GUI セッション必須） |
|---|---|
| LAN HTTP サーバ（`/v1` 全ルート） | ローカル再生（`audio.Player` / Core Audio） |
| mDNS 広告（`_uxmusic-sync._tcp`） | MTP 監視・CD リップ |
| Sync 自動ループ（`startSyncAutoLoop`） | OS メディアコントロール・Discord Presence |
| ライブラリスキャナ／ウォッチャ | YouTube 公式 embed 再生・中継（Phase 3） |
| mp3_320 トランスコード配信 | ファイルダイアログを要する操作 |

- `--sync-serve` は `--serve` のエイリアスとして残すか削除するかは実装時に判断
  （検証スクリプトが参照していれば追従修正）。
- `/v1/identity` の応答にモード情報を追加する: `roles` に `"headless"` / `"gui"` を含める。
  クライアント側はこれで「YouTube 中継が利用可能か」等を判定できる。
- 受け入れ基準: `--serve` 起動のみの mini に対して、Mobile からの閲覧・DL・再生、
  MacBook からの自動 Sync、再生回数収束がすべて成立する。

### 0-3. launchd 常駐と GUI ハンドオフ（1 マシン 1 インスタンス）

- LaunchAgent plist（`~/Library/LaunchAgents/com.uxmusic.serve.plist` 想定）:
  `RunAtLoad=true`, `KeepAlive=true`, stdout/stderr をログファイルへ。
  インストール/アンインストールは GUI の設定画面＋ CLI（`--install-agent` /
  `--uninstall-agent`）の両方から行えるようにする。
- **ハンドオフ手順（GUI 起動時）**:
  1. ポート 8765 へループバックで `/v1/identity` を照会。応答があり `roles` に
     `headless` を含むなら常駐インスタンスと判定。
  2. `launchctl bootout gui/$UID/com.uxmusic.serve` で常駐側を停止（KeepAlive との
     競合を避けるため、kill ではなく launchctl 経由で行う）。
  3. ポート解放をポーリング確認（タイムアウト付き）後、GUI モードが 8765 を bind。
  4. GUI 終了時（`OnShutdown`）に `launchctl bootstrap` で常駐側を復帰させる。
     クラッシュ終了時も KeepAlive は効かない（bootout 済みのため）ので、
     次回 GUI 起動時 or ログイン時に復旧する旨を仕様として明記する。
- **ヘッドレス側の停止受け口**: ループバック（127.0.0.1）からのみ受け付ける
  `POST /v1/local/shutdown`（認証: ローカル接続であること自体を条件とする。
  外部 IF からは 404）。launchctl が使えない異常系のフォールバック。
- 状態の一貫性: ライブラリ・設定・playcounts はすべてディスク上（`store`）にあるため、
  プロセス交代での引き継ぎ処理は不要。交代中の数秒間は API 断となることを許容する。
- 受け入れ基準: 再起動→自動常駐→GUI 起動でハンドオフ→GUI 終了で常駐復帰、の
  一連が Mobile から見て「短時間の断」以外に影響なく行える。

---

## Phase 1 — TV 基盤: tvOS ターゲットとストリーミング再生

**目的**: Apple TV 単体で Host のライブラリを閲覧・再生できる。

### 1-1. プロジェクト構成

- `UX-Music-Mobile.xcodeproj` に **tvOS ターゲット**（`UX-Music-TV`、tvOS 17+）を追加する
  （Watch 統合と同じ路線。別プロジェクトにしない）。
- 共有レイヤの抽出: `RemoteAPIClient`・モデル・`MusicPlayerService`
  （AVAudioEngine + 10 バンド EQ + LUFS 正規化）・ペアリング/接続解決
  （`RemoteConnectionResolver` の mDNS failover）を共有ターゲット（または共通
  ソースのターゲットメンバーシップ）として iOS / watchOS / tvOS から利用する。
  `AppModel` は肥大しているため丸ごと共有はせず、TV 用に必要なサービスだけを組む。
- pbxproj 注意（既知）: `objectVersion = 63`・同期グループ未使用のため、新規 `.swift` は
  pbxproj への手動登録が必要。
- ビルド/テスト: `xcodebuild -scheme UX-Music-TV -destination 'platform=tvOS Simulator,name=Apple TV' test` を整備。シミュレータ運用は既存の規律に従う（フルスイートは最後に 1 回・並走禁止）。

### 1-2. 発見とペアリング（TV は QR を「読めない」）

- **発見**: TV が mDNS `_uxmusic-sync._tcp` で Host を探索し、候補一覧を表示。
  複数 NIC/複数 Host は一覧から選択。
- **ペアリング**: 既存のデスクトップ間フロー（`POST /v1/pairing/start` → 6 桁コード・
  2 分 TTL → `confirm`）を流用する。向きは **TV がイニシエータ**。
  - **実装時判明（2026-08-11・progress/tvos-pairing.md）**: 既存 start/confirm には
    ホスト側の人手承認ステップがそもそも存在しない（コードは目視突合用の表示で、
    デスクトップ間でも開始と確定は同一操作者が連続実行。安全境界は「LAN 上で公開の
    `/v1/pairing/*` に到達できること」自体）。よって当初案の「Host GUI で承認」は
    見送り、TV は start → コード大画面表示 → confirm を自動連続実行する形に
    単純化した（サーバー変更なし・既存信頼モデルと同等）。
  - ホスト側承認（TV に限らずペアリング全体の強化）が必要になった場合は、
    別課題として `/v1/pairing/*` 全体の信頼モデルを再設計する。
- 認証は既存規約どおり `Authorization: Bearer <token>`、メディア系 GET のみ `?token=`。

### 1-3. 閲覧 UI（10-foot / フォーカスベース）

- 文字検索は主導線にしない。棚: **最近再生 / アルバム / プレイリスト / お気に入り**
  （お気に入りは Mobile 側実装状況に追従。未実装なら棚ごと出さない）。
- アートワーク主体のグリッド。データ源は `/v1/remote/songs`・`/v1/remote/playlists`・
  `/v1/remote/artwork/{id}`。
- 検索が必要な場合は tvOS 標準の検索（Siri Remote 音声入力含む）を補助として置くが、
  Phase 1 では省略可。

### 1-4. 再生（擬似ストリーミング＝先読み DL → キャッシュ再生）

- 音源取得は `/v1/remote/file/{id}` を使用。再生エンジンは Mobile と同じ
  AVAudioEngine パイプライン（EQ + LUFS 正規化）を通すため、AVPlayer の
  プログレッシブ再生ではなく **「一時キャッシュへ先読み DL → 完了後に
  AVAudioEngine で再生」** を採る（Sync Phase 3 の DownloadSyncTrack と同じ発想。
  ストリーミング専用コードパスを増やさない、という既存方針の踏襲）。
  - 現在曲＋キュー先頭 N 曲（既定 2）を先読み。
  - LAN 内なので DL は再生よりはるかに速く、体感はストリーミングと同等になる想定。
    曲頭の待ちが問題になった場合のみ、部分再生（DL 中ファイルの追いかけ再生）を
    検討する（Phase 1 では作らない）。
- **キャッシュ規律（tvOS 制約の明文化)**:
  - 置き場所は `Caches`（OS がパージし得る前提）。上限サイズ（既定 2GB 目安・
    実装時に調整）＋ LRU 削除。
  - キャッシュはあくまで再生バッファ。「ダウンロード済み」概念を UI に出さない。
  - オフライン（Host 不達）時は再生不可でよい。エラー表示＋再接続導線のみ。
- ラウドネス値は `/v1/remote/loudness` から取得し、Mobile と同じ
  `targetLUFS - songLUFS` → `pow(10, gainDb/20)` を適用。
- 受け入れ基準: TV 単体でペアリング→棚閲覧→連続再生（ギャップ体感なし）→
  TV/AV アンプ出力で音量感が Mobile と揃う。

---

## Phase 2 — 大画面 Now Playing・同期歌詞・アンビエント

**目的**: TV ならではの「見せる」体験。

- **Now Playing 全画面**: 大判アートワーク＋曲情報。tvOS 標準の
  Now Playing インフラ（MPNowPlayingInfoCenter / リモコンの再生制御）に対応。
- **同期歌詞**: 歌詞データは `/v1/remote/lyrics` から取得し、現在行ハイライトの
  大画面表示。既存の歌詞同期資産（lyricssync）のタイムスタンプ形式に準拠。
  歌詞なし曲はアートワーク表示へ自動フォールバック。
- **アンビエントモード**: 一定時間無操作でアートワーク・歌詞をスクリーンセーバー的
  演出に遷移（Ken Burns / ブラー背景など。演出詳細は実装時に別紙）。
  tvOS のスリープ設定を妨げない（再生中のみ画面維持）。
- 任意（余力があれば）: ビジュアライザ移植（デスクトップの FFT 資産の流用検討）。
- 受け入れ基準: 再生中に放置して「リビングの音楽ディスプレイ」として成立する。

---

## Phase 3 — Connect 化・YouTube 中継・再生回数収束（ゴール）

**目的**: 「TV は目と耳、iPhone は手」の完成。

### 3-1. TV を再生ターゲットにする（Connect 型）

- TV 側にも `/v1/remote/state`・`/v1/remote/command` 相当の**受け口**を実装する
  （TV 上で軽量 HTTP サーバを起動。認証は Host と同じ Bearer 方式で、トークンは
  ペアリング時に相互交換するか、Host 経由で配布する — 実装時に
  `progress/lan-api-v1.md` へ追記の上で決定）。
- TV は mDNS で自身を広告（`_uxmusic-remote._tcp` 等の新サービスタイプ。
  既存 `_uxmusic-sync._tcp` と分けるかは実装時判断、仕様書へ反映）。
- Mobile の Remote タブ／デスクトップ GUI に**再生先ピッカー**を追加:
  「この iPhone ／ Apple TV ○○」から選択 → 選曲・キュー操作・音量が TV に反映。
- キューの実体は TV 側が保持（Host からの取得も TV 自身が行う）。操作側は
  command を送るだけにして、操作端末が眠っても再生が続く形にする。

### 3-2. 再生回数の収束参加

- TV での再生完了を Host に報告する軽量エンドポイントを新設:
  `POST /v1/remote/play-event`（body: trackId, playedAt, durationPlayed 等）。
  Host 側で `syncSongMatchKey` に変換して既存の `sync-play-events` ストアへ積み、
  デスクトップ間収束（`playcounts = base + logCount`）にそのまま乗せる。
  TV を Sync ピアにせずに収束へ参加させるための最小の橋。仕様は
  `progress/lan-api-v1.md` に追記する。
- Watch/Mobile も将来この統一報告経路に寄せられるが、本計画のスコープ外。

### 3-3. YouTube 音声中継（放送型）

- **送信側（PC・GUI モードのみ）**: 公式 IFrame 再生のプロセスタップ済み PCM を
  エンコードし、`GET /v1/remote/relay`（chunked HTTP）で配信。
  - コーデックは AAC-LC 256kbps を第一候補（tvOS/iOS のハードウェアデコード前提。
    Opus は互換性検証後の代替）。実装時にレイテンシ実測の上で確定し本紙を更新。
  - メタデータ（曲名・サムネイル・再生状態）は `/v1/remote/state` を拡張して配信
    （relay 再生中フラグ＋ YouTube メタ）。プッシュが必要になったら SSE 化を検討。
  - capability 名 `remote.relay.v1` を `/v1/identity` の `capabilities` で広告。
    **GUI モード時のみ広告**し、ヘッドレス時は存在しない機能として扱う。
- **受信側（TV / iPhone）**: capability を検知したら「PC で再生中の YouTube」を
  再生先として提示。受信中はローカル再生パイプラインを一時停止。
  放送型のため、シーク・曲送りの操作主体は PC 側（受信側からの command 転送は
  任意実装）。
- **公式 YouTube アプリへのハンドオフ（おまけ・可否検証込み)**: TV の UI 上の
  YouTube 項目から、公式アプリをスキーム起動できるか検証（tvOS の
  `UIApplication.open` ＋ YouTube アプリのスキーム/ユニバーサルリンク対応次第）。
  不可なら本項目は落とす（計画上のリスクとして織り込み済み）。
- 受け入れ基準: PC で YouTube を公式再生 → TV/iPhone で数秒以内に同じ音声が
  再生され、TV に曲名・サムネイルが表示される。ヘッドレス時は中継 UI 自体が
  出ない。

---

## 明文化事項（今回の議論で確定した詳細）

設計判断として確定し、以後の実装で前提とするもの:

1. **単一バイナリ**: デーモン分離（別バイナリ `uxmusicd`）は行わない。再提案しない。
2. **1 マシン 1 インスタンス**: GUI と常駐の同時起動はさせず、launchctl ハンドオフで解決。
3. **TV は Sync ピアではない**: `/v1/sync/*` を TV から叩かない。ミラー/選択キャッシュ・
   統一ライブラリビューの機構を TV に持ち込まない。
4. **TV に恒久 DL なし**: キャッシュは OS パージ可能な再生バッファのみ。UI 上も
   「ダウンロード」を見せない。
5. **TV の再生は擬似ストリーミング**: 先読み DL → AVAudioEngine 再生。EQ/LUFS を
   全端末で通すため AVPlayer 直ストリーミングは採らない。
6. **YouTube は放送型中継**: 音源は常に PC の公式 embed 再生 1 本。還元は PC 側の
   公式再生で発生。クライアント別動画・映像中継はやらない。グレー抽出は復活させない。
7. **tvOS にブラウザは存在しない**: 「TV でブラウザを呼ぶ」案は不成立と確認済み。
   代替は中継受信＋公式アプリハンドオフ（要検証）。
8. **ヘッドレス時に落ちる機能を仕様として明示**: ローカル再生・MTP・CD リップ・
   OS メディアコントロール・Discord・YouTube 中継・ダイアログ操作。
   `/v1/identity` の `roles`（`gui`/`headless`）で判別可能にする。
9. **ペアリングの向き**: Mobile = QR（既存）、TV = start/confirm 流用で TV 画面に
   コード表示 → Host 側承認。生トークンの直配布はしない（既存規約踏襲）。
10. **API 追加はすべて `/v1` 名前空間**で行い、`progress/lan-api-v1.md` を先に更新
    してから実装する（SSoT 維持）。

## 未確定（実装時に決めて本紙・SSoT に反映するもの)

- 中継コーデックの最終確定（AAC-LC 想定、レイテンシ実測後）。
- TV 受け口の mDNS サービスタイプとトークン配布方式（3-1）。
- `--sync-serve` エイリアスの存廃。
- 公式 YouTube アプリのスキーム起動可否（不可なら項目ごと削除）。
- 追いかけ再生（部分再生）の要否（曲頭待ちが実測で問題になった場合のみ）。

## リスクと備え

| リスク | 備え |
|---|---|
| launchctl ハンドオフの競合（KeepAlive が bootout 前に再起動を挟む等） | kill ではなく launchctl 経由に統一・ポート解放をポーリング確認・失敗時は GUI がサーバなしで起動して警告表示 |
| tvOS のキャッシュパージが再生中に走る | 再生中ファイルはオープン済み fd で保持・パージ検知で再 DL |
| AVAudioEngine 系コードの tvOS 非互換（セッションカテゴリ等の差分） | Phase 1 冒頭で最小再生スパイクを最初に通す（計画の先頭で失敗を検知） |
| 中継レイテンシが大きく「放送」として不自然 | コーデック/バッファ長の調整余地を設計に残す。数秒遅延までは許容と割り切る |
| GUI 承認なしでの TV ペアリング（完全ヘッドレス Host） | Phase 1 では「ペアリング時のみ GUI」運用で許容。Mobile からの承認 UI は Phase 3 任意項目 |

## 実施順序（依存関係）

```
Phase 0-1 (emit 抽象化)
   └→ Phase 0-2 (--serve 完全化) ─→ Phase 0-3 (launchd/ハンドオフ)
Phase 1-1 (tvOS ターゲット+共有抽出) ─→ 1-2 (ペアリング) ─→ 1-3/1-4 (UI/再生)
   ※ Phase 1 は Phase 0-2 完了後に着手（ヘッドレス Host 相手に開発するため）
Phase 2 (Now Playing/歌詞/アンビエント) — Phase 1 完了後
Phase 3-1 (Connect) / 3-2 (play-event) / 3-3 (YouTube 中継) — 相互独立、並行可
```
