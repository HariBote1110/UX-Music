# iOS 版 発熱要因の静的レビュー（2026-10）

## 目的 / 仮説

「端末がとても熱くなることがある」という報告に対し、**持続的に CPU / GPU / 無線を起こし続ける箇所**を
コードから洗い出す。発熱は瞬間的な重さより「止まらない常時コスト」で起きるため、タイマー・ポーリング・
動画デコード・バックグラウンド継続を重点的に見た。

2026-08 の `static-review-2026-08.md` の続編。そちらの 1・2・3（書き込み側）・4 は対策済みを確認した
（stem 辞書化、`LibraryDerivedCollections`、`ProgressPublishThrottle`、`preparingThumbnail` +
`ArtworkMemoryCache` の iOS 配線）。

## 環境

- 対象: `UX-Music-Mobile/UX-Music-Mobile/`（main、f003476e、2026-10-27）
- 手法: grep + コードリーディングのみ。**実測なし**（実機 Instruments 未実施）

## 結果（疑いの強さ順）

### A. RemoteControlScreen のポーリングがタブを離れても・バックグラウンドでも止まらない — 最有力

- `Views/RemoteControlScreen.swift:113-118`: `onAppear` で 2 秒周期ポーリング開始、`onDisappear` で停止。
- しかし `Views/HomeRootView.swift:87-109` の `LazyTabRoot` は一度訪れたタブを `opacity(0)` で残すため
  **`onDisappear` が発火しない**。Control タブを一度開くと以後ずっと 2 秒ごとに HTTP GET + JSON デコード。
- `scenePhase` にも連動していない（サイドカー側 `AppModel.startSidecarPolling` は連動済み）。
  音楽再生中はアプリがサスペンドされないので、**画面オフ・バックグラウンド再生中も 2 秒ごとに Wi-Fi を起こし続ける**。
- PC が落ちている／別ネットワークでは毎回失敗 → `RemoteConnectionResolver.withFailover` のフォールバック候補巡回と
  `LANDiscoveryService.resolvePairedPeer`（Bonjour browse + 50ms 刻みで 1 秒待機）に入る可能性がある（要確認）。

**対策方向**: 「タブが選択中 かつ scenePhase == .active」の時だけポーリング。LazyTabRoot から
`isSelected` を環境値で子へ流す。

### B. 再生位置タイマー 4Hz が一時停止・停止後も永久に回り、毎回 Now Playing 情報を全書き換え

- `Services/MusicPlayerService.swift:730-739`: 0.25s Timer。`invalidate` は再起動時のみで、
  **pause / stop / キュー終了でも止まらない**（2026-08 レビュー 6 が未対策のまま）。
- 毎ティック `updateNowPlayingCentre()`（`:1829-`）が `MPRemoteCommandCenter` の isEnabled 6 個と
  `MPNowPlayingInfoCenter.nowPlayingInfo` を丸ごと再代入 → mediaserverd への IPC、ロック画面 /
  コントロールセンター / Watch の Now Playing 再描画を 4Hz で誘発。
  経過時間は `ElapsedPlaybackTime + PlaybackRate` からシステムが補間するので本来は状態変化時だけで足りる。
- `positionSeconds`（@Observable）も 4Hz で書かれ、読む View（進捗バー・歌詞）が再評価される。

**対策方向**: `isPlaying == false` でタイマー停止。Now Playing 更新は曲・再生状態・シーク時のみに限定し、
ティックでは `positionSeconds` だけ更新。画面に進捗が出ていない時（バックグラウンド）はティック自体不要。

### C. YouTube 再生: 見えていない動画を Wi-Fi 時は既定画質でデコードし続ける＋二重ポンプ

- `Services/YouTubePlaybackHost.swift:353-370`: Now Playing を閉じると WKWebView を 256×144 の
  画面外 `parkingView`（alpha 0.01）へ退避するが、**動画デコードは継続**。低画質化は
  `shouldUseLowQuality`（`YouTubeEmbedPlayer.swift:90`）で**セルラー時のみ**。
  Now Playing 表示中に上がった画質のまま裏でデコードしている可能性。
- JS 側 `setInterval` 250ms（`YouTubeEmbedPlayer.swift:331`、`time` + `getPlaybackQuality`）+
  PiP 状態監視 1000ms（`YouTubePlaybackHost.swift:150`、JSON.stringify 比較）+ ネイティブ側 B の 4Hz
  タイマー（外部駆動時も `updateNowPlayingCentre` を呼ぶ）が重なる。
- 一時停止中も JS タイマーは止まらない（`startTimer` に対応する停止が state 変化で呼ばれるか未確認）。

**対策方向**: 動画が見えていない間は `setPlaybackQuality('small')`（相当の小サイズ）を Wi-Fi でも適用、
JS タイマーは PLAYING 時のみ、可能なら 1Hz に落とす。

### D. Now Playing 画面の全画面合成コスト（中）

- `NowPlayingAmbientBackground`（`Views/NowPlayingView.swift:837-`）: 全画面グラデーション 3 枚、
  うち 2 枚が `.blendMode(.plusLighter)` → オフスクリーン合成。
- アートワークに半径 32 / 40 の二重 `.shadow`（`:966-967`）、再生ボタンに半径 24 の shadow（`:724`）。
- B の 4Hz 進捗更新のたびに画面が再合成されるので、Now Playing を開きっぱなしにすると GPU が休まらない。
  静的な部分は `drawingGroup()` / 事前ラスタライズで固定化できる余地。

### E. 歌詞 TimelineView 5Hz（低）

- `Views/NowPlayingLyricsScreen.swift:259`、`SidecarScreen.swift:330,619`: 0.2s / 0.25s 周期。
  `@State` 書き込みは行変化時のみにガード済みでクリーン。ただしティック毎に `.task(id:)` が Task を生成する。
  一時停止中は止めてよい。

### F. Album / Artist / RemotePlaylist 詳細が非 Lazy VStack（低〜中、発熱よりカクつき）

- 2026-08 レビュー 5 が未対策。`AlbumDetailView.swift:29-30`、`ArtistDetailView.swift:23-24`、
  `RemotePlaylistDetailView.swift:59-60`。曲数の多いアーティストを開いた瞬間に全行構築。

### クリーンと確認

AVAudioEngine は一時停止時に `engine.stop()` 済み（`MusicPlayerService.swift:1688` 付近）、
EQ はフラット時 bypass（`:582-586`）、サイドカーポーリングは scenePhase 連動、
アートワークはダウンサンプル + メモリキャッシュ済み。

## 結論

発熱の筋として最も濃いのは **A（バックグラウンドでも止まらない 2 秒ポーリング）** と
**B（止まらない 4Hz タイマー + Now Playing 全書き換え）**。どちらも「再生していない／見ていない間もコストが出続ける」
型で、長時間使用で効く。YouTube 再生時は **C** が加わり、動画デコードがそもそも最大の電力消費源なので
YouTube 曲を連続再生している場面では C が支配的になると見立てる。

## 対策状況（2026-10-27 追記）

- A・B は TDD で実装済み（45e54b7c〜c636260a、判断記録は `progress/mobile-thermal-polling-timer.md`）。実機での効果測定は未了。C も実装済み（17acc5e2〜78c57de7、PiP の 1000ms 監視は対象外）。D も実装済み（71992538〜27ed0393）。E・F も実装済み（d2a7a6b0〜1b27a49a）。実機での前後比較は `device-energy-harness-2026-10.md` を参照（A・B は効果を確認。C は未確定）。

## 次の一手 / 未検証事項

- 実機（Xcode → Debug Navigator の Energy Impact、または Instruments の Energy Log / Time Profiler /
  Network）で以下のベースラインを取る。シミュレータは熱・無線を再現しないので実機必須。
  1. Control タブを一度開いてから Library に戻り、画面オフでローカル曲を 10 分再生（A の検証）
  2. ローカル曲を一時停止したまま 5 分放置（B の検証: CPU ウェイクアップ回数）
  3. YouTube 曲を Now Playing 閉じた状態で 10 分再生、Wi-Fi / セルラー比較（C の検証）
- A の失敗時経路（PC 不在時に毎回 Bonjour browse が走るか）は `RemoteConnectionRecoveryCoordinator` の
  抑制ロジックを読んで確定させる。
- 修正は A → B → C → D の順が費用対効果順の見立て。いずれも `/development`（TDD）で実装する。
