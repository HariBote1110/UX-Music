# 音楽プレーヤー「UX Music」機能仕様書 (v0.1.9-Beta-35c)

## 概要
ローカル・オンラインの音源を統合的に管理・再生できるデスクトップ音楽プレーヤー。Electronフレームワークを基盤とし、音源のインポート、再生、管理に関する多岐にわたる機能を提供。独自ライブラリ管理だけでなく、CDリッピングやMTP転送など、オーディオマニア向けの機能も充実している。

## 技術スタック
- **フレームワーク:** Electron
- **言語:** JavaScript (Node.js), HTML5, CSS3
- **主要ライブラリ:**
  - `discord-rpc` (Discord Rich Presence連携)
  - `sharp` (アートワークのサムネイル生成・画像処理)
  - `@distube/ytdl-core` (YouTubeのメタデータ取得および動画ダウンロード)
  - `music-metadata` (音声ファイルのメタデータ解析)
  - `fluent-ffmpeg`, `ffmpeg-static` (音声ファイルのラウドネス値・BPM・雰囲気解析・ノーマライズ処理)
  - `music-tempo`, `wav-decoder`, `tmp` (BPM解析)
  - `koffi` (ネイティブライブラリ呼び出し - MTP/CDPARANOIA)
  - `usb-detection` (USBデバイス接続検知)

---

## 主要機能

### [新規] CDリッピングツール (UX Rip)
オーディオCDを高品質にリッピングし、ライブラリに追加するツール。
- **高機能な吸い出し**: `cdparanoia`エンジンの利用により、傷のあるCDでも高精度な読み取りが可能。
- **MusicBrainz連携**: DiscIDおよびテキスト検索により、オンラインデータベースからアルバム情報を自動取得。
- **アートワーク埋め込み**: [Cover Art Archive](https://coverartarchive.org/)からジャケット画像を自動取得し、リッピングしたファイルに埋め込む。
- **多彩なフォーマット**: ALAC (Apple Lossless), FLAC, MP3, AAC, WAV に対応。

### [新規] MTPデバイス転送 (UX MTP)
macOSから直接WalkmanなどのMTPデバイスへ音楽を高速転送する機能。
- **スマート同期**: macOS標準では困難なMTPデバイスへのアクセスを独自に実装。
- **デバイス管理**: 接続されたデバイスのストレージ容量、モデル情報をリアルタイムに取得。
- **独自プロトコル**: 高速かつ安定したファイル転送を実現。

### [更新] iOS コンパニオン / Wear 連携
同一 LAN 上のモバイルクライアントからライブラリ閲覧・音源取得・再生操作を行う連携機能。
- **ペアリング認証**: QR ペアリング URL に認証トークンを含め、`/wear/songs`、`/wear/file`、`/wear/command` などの実データ・操作 API はトークン無しのアクセスを拒否する。
- **安全なCORS**: LAN クライアント向けの CORS を維持しつつ、認証済みリクエストだけがライブラリや再生操作へ到達できる。

### [新規] UX Sync Phase 1
同一 LAN 上の PC 間同期に向けた基盤機能。
- **同期専用ペアリング**: `/sync/pairing/start` で期限付きペアリングセッションと6桁確認コードを発行し、`/sync/pairing/confirm` でコード一致後に同期専用トークンを返す。
- **認証分離**: `/wear/*` と `/sync/*` は同じ LAN HTTP サーバー上に載せるが、Wear 認証トークンと Sync 認証トークンは別 middleware で扱う。
- **再生イベント同期**: `Portable Client` から `Library Host` へ `/sync/library/events` で `PlayEvent` をバッチ送信できる。同じ `eventId` の再送は冪等に無視し、同じ曲を複数端末で同時再生した場合は別イベントとして両方を採用する。
- **イベントログ基盤**: 既存 `playcounts` へ直接加算せず、`sync-play-events` のイベントログを保存し、再生回数はイベント集計から算出できるようにする。

### [新規] UX Sync Phase 2
同一 LAN 上の UX Music 端末を自動発見するための mDNS / Bonjour 基盤。
- **サービス広告**: LAN HTTP サーバー起動時に `_uxmusic-sync._tcp.local.` を広告し、端末ID、表示名、プロトコル版、役割を TXT レコードに含める。
- **サービス探索**: `DiscoverSyncDevices(timeoutMs)` から mDNS 探索を実行し、発見した peer を `deviceId`、`displayName`、`host`、`hosts`、`port`、`roles` として返す。
- **複数NIC対応**: Mac mini のように複数の LAN / Wi-Fi / Tailscale アドレスを持つ環境では、代表 `host` だけでなく `hosts` に全候補を保持する。
- **自動到達性確認**: 発見した `hosts` 候補へ `/sync/identity` を順番に probe し、最初に応答した URL を `reachableBaseUrl` として返す。末端側は IP 手入力や OS の `dns-sd` 操作を行わず、アプリ側の mDNS 探索と自動 probe で接続候補を得る。
- **macOS Bonjour fallback**: macOS では Go の `zeroconf` discovery と OS 標準の `dns-sd -B/-L` 結果をマージし、複数 NIC / VLAN 環境で一部 peer を取りこぼす場合も同じ `MDNSPeer` 形式へ正規化する。

### [新規] UX Sync Phase 3
設定画面から UX Sync の自動発見結果を確認する UI。
- **探索導線**: 設定モーダルの UX Sync セクションから「同期端末を探す」を実行し、Wails の `DiscoverSyncDevices(timeoutMs)` を呼び出す。
- **到達候補表示**: 発見した peer ごとに表示名、`reachableBaseUrl` 優先の接続候補、役割、複数 NIC の候補アドレスを表示する。
- **環境フォールバック**: Wails binding が無い renderer 単体開発環境では UX Sync セクションを非表示にし、通常の設定画面を壊さない。

### [新規] UX Sync Phase 4
設定画面の UX Sync 自動発見一覧から、発見済み端末と6桁コード確認ペアリングできる UI。
- **ペアリング開始**: peer カードの「接続」から Wails の `StartSyncPairing(baseURL)` を呼び、リモート `/sync/identity` と `/sync/pairing/start` の結果としてリモート端末名、端末ID、一時セッションID、6桁コードを表示する。
- **ペアリング確定**: 表示した6桁コードを確認して「確定」を押すと `ConfirmSyncPairing(baseURL, sessionID, code, expectedRemoteDeviceID)` を呼び、リモート `/sync/pairing/confirm` が返した同期トークンをローカル設定のリモート `deviceId` 宛に保存する。
- **端末一致確認**: 確定時に再取得したリモート `deviceId` が、開始時に表示した `remoteDeviceId` と一致しない場合はトークンを保存しない。
- **到達URL選択**: UI は `reachableBaseUrl` を優先し、未取得時は `host` / `hosts` と `port` からペアリング用 URL を構成する。URL が構成できない peer は接続ボタンを無効にする。

### [新規] UX Sync Phase 5
UX Sync の探索・ペアリング・同期状態を扱う専用設定画面。
- **専用入口**: 通常の設定モーダルには `UX Sync設定を開く` の入口だけを置き、Wails sync binding が無い環境では入口ごと非表示にする。
- **端末画面**: UX Sync 専用設定画面の `端末` タブに、探索ボタン、探索状態、発見 peer 一覧、既存の6桁コード確認ペアリング導線を集約する。
- **拡張余地**: `同期` と `保存` のタブ枠を用意し、後続のアウトボックス状態、差分同期、圧縮キャッシュ設定を同じ画面へ追加できる構造にする。

### [更新] UX Sync Windows側発見fallback
Windows 側で mDNS discovery が空になる環境でも、ペアリング済み Mac mini を見失わないための補正。
- **広告名正規化**: mDNS instance / TXT `displayName` に使う表示名から `.local` suffix を除去し、`YukinoMac-mini.local` ではなく `YukinoMac-mini` として広告する。
- **既知peer保存**: inbound pairing の confirm 成功時、相手 `deviceId`、表示名、実通信元 IP から `http://{remote-ip}:8765` を既知 peer として `settings.syncKnownPeers` に保存する。
- **発見fallback**: `DiscoverSyncDevices(timeoutMs)` と `/sync/discover` は mDNS 結果に `syncKnownPeers` をマージし、mDNS browse が不安定でもペアリング済み端末を候補に出す。
- **手動ペアリング**: mDNS が使えないネットワークでは、UX Sync 専用設定画面の `端末` タブに IP / ホスト名と任意ポートを入力し、既存の6桁コード確認ペアリングを開始できる。

### [新規] UX Sync 音源pull MVP / SSH検証CLI
ペア済み端末から、GUI を経由せず最小の音源転送を検証できる。
- **ライブラリスナップショット**: `/sync/library/snapshot` は同期トークンを要求し、アートワーク blob を除いた曲一覧を返す。送信側に再生回数がある曲は `syncPlayCount` を含め、音源未取得の remote 曲でも再生回数を表示できる。
- **音源取得**: `/sync/assets/{trackId}/file` は同期トークンを要求し、登録済み曲IDに対応するローカル原本ファイルだけを返す。`encoding=mp3_320` かつ peer が `library.transcode.mp3-320.v1` を持つ場合は、元が非 MP3 の曲を MP3 320kbps としてストリーミング配信できる。任意パス指定は受け付けない。
- **子側pull取り込み**: `PullSyncLibraryAssets(baseURL, limit)` は保存済み `syncAuthTokens` を使って親へ接続し、受信音源を子側ユーザーデータ配下の `SyncLibrary` に保存し、`library.json` へ `syncSourceDeviceId` / `syncSourceTrackId` 付きで取り込む。受信した `syncPlayCount` は実保存パスの `playcounts` と再計算用の `playcounts-base` に反映し、既に取得済みの曲は音源を再取得せず再生回数だけ更新する。`settings.syncPreferredFormat="mp3_320"` の端末は対応 peer から MP3 320kbps を取得し、非対応 peer では原本取得へフォールバックする。
- **SSH検証CLI**: `--sync-reset-test-data` はペアリング情報を温存して検証用ライブラリ状態を初期化し、`--sync-pull-one` / `--sync-pull` は WebView2 を起動せず SSH から音源pullを実行する。
- **GUI操作**: UX Sync 専用設定画面の `端末` タブから mDNS 探索または手動入力でペアリングを開始できる。`同期` タブから同期元 peer を選択し、`1曲取得` または `全曲取得` を実行できる。実行結果は取得数・既存数・失敗数と保存先パスとして表示する。
- **ペア済み端末復元**: `ListSyncDevices()` は保存済み `syncAuthTokens` と `syncKnownPeers` から同期トークンを返さずにペア済み端末一覧を返す。UX Sync 専用設定画面は mDNS discovery が空でもこの一覧を端末表示と同期元候補へマージし、画面を閉じた後もペアリング済み状態を維持する。
- **push転送**: `/sync/library/import` は同期トークンを要求し、ペア済み端末から multipart で届いた音源とメタデータを `SyncLibrary` へ保存する。`PushSyncLibraryAssets(baseURL, limit)` はローカルライブラリの音源を相手端末へ転送し、UX Sync 専用設定画面の `同期` タブから `1曲転送` / `全曲転送` を実行できる。
- **転送進捗と圧縮転送**: UX Sync 専用設定画面は転送中のファイル名、件数、転送量、転送速度を表示する。`PushSyncLibraryAssetsWithOptions(baseURL, limit, { encodingMode: "mp3_320" })` により、FLAC などの重い音源を MP3 320kbps へ変換しながら転送できる。
- **再生回数の自動同期**: ローカル再生回数の加算時に `PlayEvent` を `sync-play-events` へ記録し、接続可能なペア済み端末へ定期的に `/sync/library/events` でpushする。受信側は新規イベントだけを既存 `playcounts` へ反映し、同じイベントの再送では二重加算しない。
- **ジャケットの自動補完同期**: `/sync/assets/{trackId}/artwork` は同期トークン付きで保存済みジャケットを返す。`AutoSyncPairedDevices()` は接続可能なペア済み端末に対し、既に取り込み済みの同期曲で欠けているジャケットを自動取得し、`Artworks` と `Artworks/thumbnails`、`library.json` の `artwork.full` / `artwork.thumbnail` に反映する。
- **空き容量安全停止と保存形式**: `settings.syncMinFreeSpaceGB` が正の値の場合、UX Sync は保存先ボリュームの空き容量が指定GB未満の時に自動同期、音源取得、音源受信を停止する。UX Sync 専用設定画面の `保存` タブから最低空き容量と pull 側の優先フォーマット（原本 / MP3 320kbps）を変更できる。
- **プロトコルスキーマ**: `/sync/schema` は `protocolVersion`、`schemaVersion`、capability、endpoint、message、拡張規則を含む機械可読スキーマを返す。`/sync/identity` は client が送る `X-UX-Music-Sync-Protocol-Version` / `X-UX-Music-Sync-Schema-Version` / `X-UX-Music-Sync-Capabilities` を元に negotiation 結果を返し、非互換 major の peer は同期操作前に拒否する。mDNS TXT は軽量ヒントに限定し、capability は `/sync/identity` から取得する。仕様は `markdown/ux-music-sync-protocol.md` を参照する。

### [更新] YouTubeダウンロード
YouTube URL から楽曲をライブラリに追加する際、字幕を同時取得して同期歌詞（LRC）を生成する機能。
- **有効化導線**: 「ライブラリを管理」ボタンを連続タップすると、利用同意ダイアログ経由で YouTube 機能を有効化できる。
- **Wails互換同意UI**: ブラウザ標準 `confirm` ではなくアプリ内モーダルでも同意取得できるため、Wails 環境でも有効化可能。
- **字幕選択UI**: YouTubeリンク追加時に字幕候補（言語/自動字幕/トラックID）を表示し、使用する字幕を選択できる。
- **字幕同時取得**: ダウンロード時に字幕トラック（手動字幕優先、日本語/英語優先）を探索。
- **字幕XML互換**: YouTubeの字幕XML（`<text start dur>` と `timedtext format=3` の `<p t d>`）を解析し、取得形式の差異で「字幕なし」誤判定しない。
- **同期歌詞化**: 字幕セグメントの開始時刻を LRC タイムスタンプへ変換し、自動で `.lrc` を保存。
- **歌詞導線統合**: 生成された `.lrc` は既存の歌詞表示・LRCエディタ導線でそのまま編集可能。
- **フォールバック**: 字幕が存在しない動画でも、楽曲ダウンロード自体は継続して完了する。
- **詳細ログ出力**: 字幕候補列挙・選択モード・取得失敗理由・採用字幕情報をフロント/バック双方のコンソールへ出力する。

### 音量ノーマライズツール (UX Normalize)
指定した音声ファイルの音量を一括で均一化するツール。
- **LUFSベース**: 業界標準のLUFSに基づき、ターゲット音量を調整。
- **バックグラウンド処理**: Workerスレッドによる非同期処理。
- **安全設計**: 元ファイルのバックアップ機能や、音質劣化への警告システムを搭載。

### パフォーマンスと基盤
- **高速な起動**: モジュールの遅延読み込み(`Lazy-Loading`)の実装。
- **バックグラウンド解析**: 学習・解析（ラウドネス、BPM、Energy）はWorkerスレッドで行われ、UIを妨げない。
- **Light Flightモード**: アニメーションSVGへの切り替えや画像の非表示により、極限までメモリ消費を抑える（約100MB）。

### 再生とUX
- **高音質EQ**: 10バンド・グラフィックイコライザー。Electron経路ではWeb Audio API、Wailsバックエンド再生ではGo実装のBiquadフィルタで同等設定を適用。
- **スマート検索**: ライブラリ内の楽曲を瞬時にリストアップ。
- **インポート順の安定化**: 曲インポート時の表示順はメタデータ優先（アルバムアーティスト/アーティスト、アルバム、ディスク番号、トラック番号、タイトル）で決定し、実行ごとに順序が揺れないこと。
- **仮想スクロール**: 数万曲のライブラリでもカクつかないUI。
- **コンピレーション盤のグルーピング**: アルバム一覧はアルバム名をキーに統合し、複数アーティストを含む場合は `Various Artists` 表示で扱う。
- **HR特別表示**: ハイレゾ音源（48kHz/16bit超）に対するアイコン表示。
- **再生バー音声情報ツールチップ**: シークバーと音量コントロールの間の情報ボタンにホバーすると、再生中楽曲のサンプリングレート・ビット数・ファイル形式を表示する。
- **Wailsビルド再生互換**: `ffmpeg/ffprobe` の解決時に `PATH` だけでなく Homebrew 標準パス（`/opt/homebrew/bin` / `/usr/local/bin`）と `.app/Contents/Resources` 配下を探索し、`wails build` 後でも `m4a/mp4` を再生可能にする。
- **Wailsローカル配信安全化**: `/safe-media/` はライブラリ登録済み曲のみを配信し、Windows ドライブレターを含む絶対パスも安全に復元する。`/safe-artwork/` はアートワーク保存領域外への参照を拒否する。
- **WAVシーク互換**: WAV再生時はPCMチャンク先頭基準でシーク位置を解決し、`wails` バックエンド再生でもタイムライン操作が正しく反映されること。
- **未解析曲の再生継続**: ラウドネス解析失敗時は「破損扱いでスキップ」せず、ノーマライズなし再生へ自動フォールバックすること。
- **長時間一時停止後の再開復旧**: Wails バックエンド再生では、一時停止から再開する際に出力ストリームを再起動する。30分以上の一時停止後は PortAudio ストリームを開き直し、OS のスリープや長時間アイドル後でも同じ曲を再開できること。
- **右サイドバー映像プレビュー**: `mp4` など映像付きローカル楽曲は、右サイドバーのジャケット領域を `16:9` 化して映像を表示。Wails環境では `file://` 直参照を使わず `/safe-media/` 経由で配信し、ミュート映像プレビューを再生状態（再生/一時停止/シーク）に追従同期。
- **同期歌詞UI**: Apple Music ライクな見た目（アクティブ行強調・非アクティブ行減光・滑らかな追従スクロール・左右余白の最適化・ハイライト拡大演出を維持しつつ折り返し位置安定化）で表示。

### [新規] LRCタイムラインエディタ
- **タイムライン編集UI**: 従来の打鍵方式に加え、動画編集ソフトのようなタイムライン上で歌詞クリップをドラッグして時刻調整可能。
- **プレイヘッド同期**: 再生位置をタイムライン上に表示し、タイムラインをクリックしてシーク可能。
- **オブジェクト編集**: クリップ中央のドラッグで位置移動、左右端ドラッグで開始/終了境界を伸縮可能（AviUtlライク）。
- **ルーラー倍率変更**: 倍率スライダーでタイムラインの表示倍率（ズーム）を変更でき、細かい時刻調整に対応。
- **ドラッグ時の視点固定**: クリップのドラッグ開始時にタイムラインが自動スクロールしないようにし、ルーラー位置の意図しない移動を抑制。
- **未配置行の管理**: まだ時刻がない歌詞行を一覧表示し、対象行を選択して即時に時刻付けできる。
- **既存LRC編集**: 既存 `.lrc` の読み込み・再編集に対応。LRCメタタグ（`[ar:]` など）を保持したまま保存可能。

### [新規] TXT自動同期解析 (Swift + CoreML / Python fallback)
`TXT` 歌詞から、再生中楽曲に対する `LRC` タイムスタンプを自動生成する機能。
- **対象環境**: macOS では `Swift sidecar` を優先し、非 macOS または移行途上では `Python sidecar` を利用。
- **推論エンジン**:
  - macOS 既定: ローカルの `Qwen3 Forced Aligner` / `speech` CLI が利用できる場合は、既存歌詞を直接強制アラインメントする
  - macOS fallback: `WhisperKit` + CoreML
  - fallback: `faster-whisper` を含む Python パイプライン
- **処理フロー**:
  - 既存歌詞がある場合は、素の Whisper の word timestamp ではなく、ローカル強制アラインメントを優先する
  - `Qwen3 Forced Aligner` が利用できる環境では `speech align <audio> --text <lyrics>` を呼び、単語時刻を元歌詞行へ戻して `LRC` 編集へ返す
  - aligner が無い、または `UX_MUSIC_LYRICS_SYNC_ALIGNER=off` の場合は、`Swift sidecar` が `WhisperKit` / CoreML を用いて音声認識とタイムスタンプ抽出を行う
  - Python fallback では `ffmpeg` / Demucs / faster-whisper / Stage3 アラインメントの既存パイプラインを使う
  - Python fallback では `UX_MUSIC_LYRICS_SYNC_AUDIO_SOURCES=full|vocals|both` により、元音源ASR・ボーカル分離ASR・両候補評価を切り替えられる
  - `both` では各候補をTXT歌詞へ整列し、match率・信頼度・時刻単調性・過大ギャップから参照LRCを使わず品質スコアを算出して候補を選ぶ
  - Python fallback の Stage3 では、後半の繰り返しフレーズへ大きく吸われた場合に、飛ばされたASRセグメントへ時系列順で戻す未来ドリフト修復を行う
  - Python fallback の Stage3 では、繰り返しブロック末尾が圧縮された場合に、単調化後も末尾延長補正を再適用する
  - `profile=fast` では軽量モデルと低 worker 数を使い、Python 時代よりメモリと起動コストを抑える
  - ボーカル分離・埋め込み整列・音素整列は Swift へ段階移行し、未移植段階では Python sidecar を fallback として使用可能にする
  - Go 側は sidecar の種別を意識せず、stdin/stdout JSON と `lyrics-sync-progress` の中継だけを担当する
  - TXT 行と認識セグメントの単調整列、空白/間奏行補間、時刻単調性補正は sidecar 内で完結する
- **UI導線**: LRCエディタ内の「自動同期解析」ボタン。
- **多言語対応**: 言語セレクタ（日本語 / English / 自動検出）により、Whisper に対して明示的な言語ヒントを送信。英語歌詞でも高精度な認識が可能。
- **検証支援UI**: LRCエディタ内の「検知テキスト表示」から、sidecar が検知したセグメント（開始/終了時刻・テキスト）を確認可能。
- **保存方針**: 自動保存は行わず、結果はプレビュー反映のみ。最終保存は「LRCを保存」操作時に確定。
- **ランタイム選択**:
  - `UX_MUSIC_LYRICS_SYNC_RUNTIME=swift|python|auto`
  - `auto` は macOS で Swift sidecar を優先し、起動系失敗時のみ Python fallback へ戻す。
  - `UX_MUSIC_LYRICS_SYNC_ALIGNER=auto|qwen3|off`
    - `auto`: `speech` CLI が見つかれば Qwen3 Forced Aligner を優先し、失敗時は WhisperKit へフォールバック。
    - `qwen3`: Qwen3 Forced Aligner を明示使用し、CLI が無い場合はエラー。
    - `off`: 既存の WhisperKit 経路を使う。
  - `UX_MUSIC_LYRICS_SYNC_ALIGNER_BIN` で `speech` 互換 CLI のパスを明示可能。
  - `UX_MUSIC_LYRICS_SYNC_ALIGNER_MODEL` で aligner モデルを指定可能。
  - `UX_MUSIC_LYRICS_SYNC_SWIFT_WORKERS` / `UX_MUSIC_LYRICS_SYNC_SWIFT_MODEL` で負荷と精度を調整可能にする。
  - `wails build` では `lyrics-sync-swift` を `.app/Contents/Resources/bin` に同梱し、配布後も Swift runtime を優先できるようにする。

### For You 機能 (自動プレイリスト)
- **ムード解析(Mood Analyser)**: BPM、タイトルキーワード、Energy（音量の起伏）、ジャンルを組み合わせた高度なルールエンジン。
- **シチュエーション生成**: 時刻（朝/夜）、季節、特定の日時に応じた動的プレイリスト。
- **パーソナル履歴**: 再生履歴に基づく「最近のお気に入り」「変わらない愛曲」などの生成。

---

## 今後の課題・将来的な拡張案
- **メタデータ編集機能 (Tags Editor)**: メイン画面からのID3タグ編集。
- **MP4サムネイル自動生成**: 動画ファイルからのアートワーク抽出。
- **歌詞自動取得**: オンラインサービス連携。
- **UX Sync 後続**: ペア済み端末管理、ライブラリ差分同期、プレイリスト同期、`Library Host` から `Portable Client` への圧縮音源キャッシュ、WebSocket による再生移行を実装する。LAN 外通信は初期スコープ外とし、実装計画は `markdown/ux-music-sync-plan.md` を信頼できる参照にする。
