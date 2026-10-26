# iOS 発熱対策: Control タブのポーリングと位置タイマーの抑制

調査の根拠は `mobile_perf_research/notes/thermal-static-review-2026-10.md`（項目 A・B）。

## 決定

- **Control タブのポーリング**: `RemoteControlPollingPolicy.shouldPoll` が「画面に出ている・タブが選択中・scenePhase が `.active`」の 3 条件すべてを満たすときだけ 2 秒周期の `/v1/remote/state` を回す。
  `LazyTabRoot` は訪問済みタブを `opacity(0)` で残すため `onDisappear` が来ない。そこで `EnvironmentValues.isTabSelected`（既定 `true`）で選択状態を子へ流している。
- **位置タイマー**: `isPlaying` の `didSet` で起動・停止する。`init` では起動しない。外部再生（tvOS ストリーム）も `isPlaying = true` にするので、そのまま動く。
  停止時は `settlePositionAfterPause()` で位置を 1 回確定させ、Now Playing を強制再送する。外部再生では位置の再計算はせず、再送だけ行う。
- **Now Playing の再送**: `updateNowPlayingCentre(force:)` で制御する。定期経路（位置タイマー・YouTube `.time`）だけが `force: false` で、`NowPlayingPublication.shouldPublish` が真のときに限って `MPNowPlayingInfoCenter` と `MPRemoteCommandCenter` を書く。
  再送するのは、経過時間以外の項目が変わったとき、または経過時間が補間値から 1.0 秒を超えてずれたとき（シーク・バッファ詰まり）。

## 却下した案

- タイマーを残し、`!isPlaying` のティックを早期 return するだけにする案 → 4Hz の起床そのものが残るので却下。
- `LazyTabRoot` で非選択タブを破棄する案 → 初回 push 遷移の崩れ（`mobile-ux-fixes-2026-08.md` 3 項）が再発するので却下。

## 注意点

- `setExternalPlaybackIsPlaying(false)` は自分では Now Playing を更新しない。以前は 4Hz ティックが代わりに再送していた。いまは `settlePositionAfterPause()` が担っているので、この経路を消すと tvOS の一時停止表示が「再生中」のまま残る（`testExternalPausePublishesNowPlayingAsPaused`）。
- 効果は実機で未計測。シミュレータでは発熱や無線の消費を再現できない。

## 追記: YouTube の非表示時の低画質化と JS 時刻報告（2026-10-27）

### 決定

- `YouTubeEmbedPlayer.effectiveLowQuality(preferred:isVideoVisible:)` は `preferred || !isVideoVisible` を返す。
  - `preferred` には従来どおりモバイル回線のポリシーが入る。
  - 「見えている」とは、WebView が退避用ビュー以外のコンテナに入っているか、PiP / 全画面で表示中の状態を指す。
  - 見えていないときは Wi-Fi でも、256×144 物理 px で置く低画質用の配置にする。
- JS へのコマンドは、実際に適用される画質（実効値）が変わったときだけ送る（`appliedLowQuality` と比較）。
- 埋め込みページの 250ms 時刻報告は PLAYING(1) で開始し、BUFFERING(3) 以外の状態で停止する。停止時には最終位置を 1 回だけ送る。
  - 周期を 250ms のままにしたのは、歌詞の同期がこの位置を読むため。

### 却下・保留

- PiP 状態を監視する 1000ms の `report` ポーリング → 効果が小さく、PiP 検出を壊す危険があるので触らない。
- Now Playing を開いたまま画面をロックした場合も「見えている」扱いのまま。scenePhase との連動は未対応。

### 注意点

- 再生中に WebView のサイズを小さくしたとき、YouTube が実際に画質を下げるかは実機で未検証。
- 見える状態に戻ると画質は上がるが、数秒は粗い映像になり得る。

## 追記: Now Playing の合成コスト（2026-10-27）

### 決定

- ジャケットの大きな影 2 つは、カード本体ではなく、背面に置いた不透明な角丸図形に付ける。
  - カード本体に付けていたため、YouTube 曲では動画の 1 コマごとに影が計算し直されていた。
  - カードは同じ角丸で切り抜かれているので、見た目は変わらない。
- 背景グラデーション（`plusLighter` 2 枚）は `.drawingGroup()` で 1 枚の画像にまとめる。
- 修正前後の画素比較（シミュレータ、`UXM_DEBUG_NP_LOCAL=1` の DEBUG 限定フックで表示を固定）の結果は次のとおり。
  - 背景の差は最大 2/255。
  - 角丸の縁の約 300 画素だけ最大 11/255 の差がある。背面の黒い図形が縁のアンチエイリアス越しに透けるためで、目では見分けられない。

### 未検証

- GPU 負荷が実際に下がったかは、実機の Instruments でしか測れない。
- 確認していない状態: ジャケット画像から色を取った背景、YouTube 曲の表示。
