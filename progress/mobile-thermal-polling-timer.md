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
