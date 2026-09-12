# iPhone YouTube 公式再生がバックグラウンド移行で止まる件

## 目的 / 仮説
アプリをバックグラウンドに回しても YouTube 曲（WKWebView + IFrame Player API）の再生を継続させたい。

- 仮説A: バックグラウンド移行後に WebKit が動画を一時停止するが、ネイティブから `play` を再送すれば
  再開できる（`.playback` セッション + `UIBackgroundModes=audio` で JS/WebContent が生きている前提）。
  - 棄却条件: 再送後に `state=playing` と `time` イベントが再開しない。

## 環境
- Mac（Darwin 25.6.0）/ Xcode（iOS 26.5 SDK 系）/ シミュレータ iPhone Air (iOS 26.5)
- 動画: `aqz-KE-bpKQ`（HD）/ アプリ内デバッグフック `UXM_DEBUG_YT_VIDEO`
- コミット: e161cac7 時点（WKWebView は keyWindow 内にパーキング済み）

## 手順（ベースライン）
1. `SIMCTL_CHILD_UXM_DEBUG_YT_VIDEO=aqz-KE-bpKQ xcrun simctl launch <udid> com.uxlabs.uxMusicMobile`
2. 25 秒後に `xcrun simctl launch <udid> com.apple.Preferences` でバックグラウンドへ
3. `xcrun simctl spawn <udid> log show --style compact --predicate 'eventMessage CONTAINS "UXM_DEBUG_YT"'`

## 結果（ベースライン）
| 時刻 | 事象 |
| :--- | :--- |
| 17:00:47 | バックグラウンドへ移行 |
| 〜17:00:51.9 | `time` イベント継続（再生中） |
| 17:00:52.7 | `state=paused`、以後イベントなし |

- バックグラウンド移行の約 5 秒後に一時停止され、以後 JS からのイベントも止まる。

### 変種（デバッグフックの一時的な実験フラグ。検証後に撤去済み）
- V1 `UXM_DEBUG_YT_SESSION=1`: 読み込み前に `AVAudioSession` を `.playback` で有効化（1変数目）
- V2 V1 + `UXM_DEBUG_YT_BG_RESUME=1`: バックグラウンド中に `paused` を受けたら 0.5 秒後に `play` を再送（2変数目）

| 変種 | バックグラウンド移行 | 結果 |
| :--- | :--- | :--- |
| ベースライン | 17:00:47 | 約 5 秒後 `paused`、以後イベントなし |
| V1 セッション有効化 | 17:03:34 | 約 3 秒後 `paused`、以後イベントなし（変化なし） |
| V2 V1 + play 再送 | 17:04:32 | 約 2.5 秒後 `paused` → 0.6 秒後に再送 → `buffering` のまま、`playing`/`time` は戻らず |

補足: 本番コードでも YouTube 曲の経路では `preparePlaybackSessionIfNeeded()` が呼ばれていない
（ローカル曲の `loadAndPlay` とリモートコマンドのみ）。ただし V1 の通り、有効化しても停止は防げない。

## 結論
- **仮説A: 棄却済み。** バックグラウンド中も JS は動いておりコマンドは届く（V2 で `buffering` へ遷移）が、
  iOS WebKit が動画メディアのバックグラウンド再生自体を許可しないため再開できない。
- `.playback` セッションの有効化だけでは停止を防げない（V1）。
- 公開 API での回避手段は見当たらない。WebKit のプライベート設定での回避は App Store 審査・OS 更新での
  破綻リスクがあるため採らない。

## 追加観測: バックグラウンド滞在中のプロセス SIGKILL（フェーズF 実装の検証中に発見）
環境は上と同じ（シミュレータ iPhone Air / iOS 26.5 系、デバッグフック `UXM_DEBUG_YT_SERVICE=1`）。

| 時刻 | 事象 |
| :--- | :--- |
| 17:27:10 | バックグラウンドへ移行、自前で `pause`（`didEnterBackground` の 0.2 秒後に `paused`） |
| 17:27:20 | 約 10 秒後にサスペンド（runningboard のアサーション解放、`WebProcess::updateFreezerStatus`） |
| 17:27:21.52 | サスペンド中のアプリに WatchConnectivity（`WCSession`）の File Coordination claim が発生 |
| 17:27:21.58 | `termination reported by launchd (2, 9, 9)` = SIGKILL。クラッシュレポートなし |

- 以後の `simctl launch` が "No such process" になったのはこのため（launch の制約ではない）。
- `simctl openurl uxmusic://…` で前面化すると新しいプロセスが起動する（pid が変わる）。
### 対照実験（スクリプト: 検証時は scratchpad の `verify_bg_r1_c1.sh`、手順は下表の通り）
| 実験 | 条件 | 結果 |
| :--- | :--- | :--- |
| R1 | `UXM_DEBUG_YT_SERVICE=1` で再生 → 5 秒だけバックグラウンド → `simctl openurl uxmusic://…` | `didEnterBackground` 17:30:23.68 → `paused` 23.88（位置 23.7 秒）→ `willEnterForeground` 26.65 → `buffering` 26.67 → `didBecomeActive` 27.06 → `playing` 27.43。pid 不変 |
| C1 | デバッグ env なしで通常起動（YouTube 再生なし）→ バックグラウンド | 移行約 3 秒後に `termination reported by launchd (2, 9, 9)` |

- **R1: フォアグラウンド復帰時の再開は機能する**（`willEnterForeground` で送った `play` は `buffering` を経て
  `didBecomeActive` 後に `playing` になる。バックグラウンド中の再送と違い固まらない）。
- **C1: SIGKILL は YouTube 再生・フェーズF の変更と無関係の既存事象。** 再生していない通常起動でも発生する。
  シミュレータ固有か実機でも起きるかは未検証（別課題）。

## 仮説B: PiP にすればバックグラウンドでも再生を継続できる（ユーザー判断で PiP 方式へ作り直し）
- 前提: WebKit は PiP 中のメディアのバックグラウンド再生を許可する。
- 手段: YouTube iframe はクロスオリジンだが、`WKUserScript(forMainFrameOnly: false)` は全フレームに
  注入でき、そのフレームから届いたメッセージの `WKFrameInfo` を使えばネイティブから
  `callAsyncJavaScript(_:arguments:in:in:)` でそのフレーム内の `video` を操作できるはず。
  ネイティブからの JS 実行はユーザー操作扱いになり、`webkitSetPresentationMode('picture-in-picture')`
  が許可される見込み。
- 棄却条件: (1) YouTube フレームの `video` に到達できない / `disablePictureInPicture` で拒否される、
  (2) PiP に入れない（`webkitPresentationMode` が `picture-in-picture` にならない）、
  (3) PiP 中にバックグラウンドへ回しても `time` が進まない。

### B-1: 全フレームプローブ＋ネイティブから PiP 要求（ホスト直結モード、セッション未有効化）
手順: `SIMCTL_CHILD_UXM_DEBUG_YT_VIDEO=aqz-KE-bpKQ SIMCTL_CHILD_UXM_DEBUG_YT_PIP=1` で起動
（`UXM_DEBUG_YT_SERVICE` なし＝フェーズF の一時停止ロジックは作動しない）→ 25 秒後にバックグラウンド。

| 時刻 | 観測 |
| :--- | :--- |
| 常時 | `https://www.youtube.com` フレームの `video` に到達。`disablePictureInPicture=false`、`webkitSetPresentationMode` あり |
| 常時 | `webkitSupportsPresentationMode('picture-in-picture')` = **false** |
| 19:33:00.87 | `callAsyncJavaScript(in: frame)` で PiP 要求（例外なし、直後の mode は `inline`） |
| 19:33:01.7 | `webkitPresentationMode` = **`picture-in-picture`** |
| 19:33:04.8〜07.8 | `inline` に戻る（フォアグラウンドのまま） |
| 19:33:21.6 | バックグラウンド移行 → 0.2 秒後 `paused` → 19:33:23.2 SIGKILL |

- スクリーンショット（19:33:13 前面 / バックグラウンド中）に PiP ウィンドウは写らず。
- 結論（暫定）: 棄却条件(1) は不成立（到達可能・無効化されていない）。(2) は数秒だけ成立して自動で戻る。
- 次の変数候補: `.playback` の `AVAudioSession` 未有効化（システム PiP の前提条件）。これを B-2 で有効化する。

### B-2: B-1 + PiP 要求前に `AVAudioSession(.playback, .moviePlayback)` を有効化（1変数）
手順: B-1 に `SIMCTL_CHILD_UXM_DEBUG_YT_PIP_SESSION=1` を追加。

| 時刻 | 観測 |
| :--- | :--- |
| 19:35:43.17 | セッション有効化成功 |
| 19:35:53.95 | PiP 要求 |
| 19:35:54.9〜19:36:00.9 | `webkitPresentationMode` = `picture-in-picture`（約 6 秒） |
| 19:36:00.97 | `inline` に戻る |
| 19:36:11.7 | バックグラウンド → 0.3 秒後 `paused` → 19:36:13.2 SIGKILL |

- `webkitSupportsPresentationMode('picture-in-picture')` は B-1 同様 false のまま。
- バックグラウンド中のスクリーンショットには Dynamic Island の再生インジケータのみで PiP ウィンドウなし。
- `mode = picture-in-picture` の最中（19:35:57）のスクリーンショットにも PiP ウィンドウは写らない。
  つまり WebKit 側のフラグが一時的に切り替わるだけで、システムの PiP ウィンドウは一度も出ていない。
- 結論（B-3 で訂正）: シミュレータでは PiP 自体が非対応だったため、**判定不能**（棄却ではない）。

### B-3: B-2 + パーキング先 WKWebView を画面内・alpha 1 に表示（1変数）
手順: B-2 に `SIMCTL_CHILD_UXM_DEBUG_YT_PIP_VISIBLE=1` を追加（起動 3 秒後に 256x144pt で画面上に表示）。

| 時刻 | 観測 |
| :--- | :--- |
| 19:38:22.98 | **`AVPictureInPictureController.isPictureInPictureSupported()` = false** |
| 19:38:26.03 | WKWebView を画面内 (20,140,256,144) に表示 |
| 19:38:34.74 | PiP 要求 |
| 19:38:35.6〜19:38:39.6 | `webkitPresentationMode` = `picture-in-picture` |
| 19:38:37 | スクリーンショット: 動画はインラインのまま画面内で再生、PiP ウィンドウなし |
| 19:38:40.65 | `inline` に戻る |
| 19:38:52.7 | バックグラウンド → 0.2 秒後 `paused` → 19:38:54.1 SIGKILL |

- 結論: **このシミュレータはシステム PiP 非対応**（`isPictureInPictureSupported=false`、
  `webkitSupportsPresentationMode('picture-in-picture')=false`）。WebKit のフラグは要求に応じて
  一時的に切り替わるが実体の PiP は起動せず、数秒でタイムアウトして戻っている。
- したがって B-1〜B-3 は**仮説B の反証にはならない（シミュレータでは検証不能）**。
  到達性（YouTube フレームの `video` に触れる・`disablePictureInPicture` が false・ネイティブからの
  要求が例外なく受理される）だけは確認済み。

### B-4: 実機（YkiPhoneAir / iPhone Air 実機、開発ビルド）で B-2 相当
手順: スクリプト `verify_pip_device.sh`（検証時は scratchpad）。`xcodebuild -destination id=<device>
-allowProvisioningUpdates` → `devicectl device install app` → `devicectl device process launch --console
--environment-variables '{"UXM_DEBUG_YT_VIDEO":"aqz-KE-bpKQ","UXM_DEBUG_YT_PIP":"1","UXM_DEBUG_YT_PIP_SESSION":"1"}'`
→ 25 秒後に `devicectl device process launch com.apple.Preferences` でバックグラウンドへ → 20 秒観測。

| 時刻 / 再生位置 | 観測 |
| :--- | :--- |
| 19:41:34.59 | `isPictureInPictureSupported` = **true**、セッション有効化成功 |
| 起動直後〜 | `webkitSupportsPresentationMode('picture-in-picture')` = **true** |
| 19:41:41.14 | PiP 要求 |
| t=6 秒〜 | `webkitPresentationMode` = `picture-in-picture`（以後観測終了まで維持） |
| 19:42:00.72（t≈24 秒） | バックグラウンド移行 |
| t=24〜43.7 秒 | `time` イベントが 2 秒ごとに進み続け、`paused=0` のまま。`paused` 状態イベントなし |

- ユーザー目視: 映像（PiP ウィンドウ）は出ていた。音は聞こえなかった気がする。
  → ホスト直結モードでは `MusicPlayerService` が `.ready` を無視し `unmute` を送らないため、
  埋め込みページの `mute:1` のまま（想定内。PiP の問題ではない）。
- 結論: **仮説B は実機で成立。** ネイティブから YouTube iframe の `video` を PiP にでき、PiP 中は
  バックグラウンドでも再生が継続する。SIGKILL も観測されなかった（再生中はサスペンドされない）。

### G-1: 本実装（フェーズG）を実機で検証 — トリガー `.didEnterBackground`
手順: `verify_pip_device_service.sh`（検証時は scratchpad）。`UXM_DEBUG_YT_SERVICE=1` で
`MusicPlayerService` 経由（unmute される経路）で再生 → 20 秒後に設定アプリを前面へ → 20 秒後に UX Music へ戻す。
ログは `devicectl device process launch --console` の出力。

| 時刻 | 観測 |
| :--- | :--- |
| 20:15:26.48 | `didEnterBackground` → `[UXM_YT_PIP] entering trigger=didEnterBackground` |
| 20:15:26.63 | WebKit から `paused` |
| 20:15:26.76 | `[UXM_YT_PIP] failed trigger=didEnterBackground` → フォールバック（一時停止＋復帰時再開） |
| 20:15:40.52 / 20:15:45.06 | 同じ流れ（`paused` 約 0.2 秒後 → `failed` → フォールバック） |
| 20:16:05〜06 | フォアグラウンド復帰 → `buffering` → `playing`（フォールバックの再開は機能） |

- `unavailable` は一度も出ておらず、フレーム検出・可用性判定は正常。
- ユーザー目視: バックグラウンド中は PiP ウィンドウが出ず、音も止まった。
- 20:15:26 / 20:15:40 の前後の往復はスクリプトの切り替え前に発生しており、`devicectl` のアタッチ由来とみられる。
- 結論: **`didEnterBackground` 時点での PiP 要求は常に失敗する**（通知の約 0.2 秒後には WebKit が
  インライン動画を止めており、その後の PiP 要求は通らない）。トリガーを `willResignActive` に変更して再検証する。

## 次の一手 / 未検証事項
- G-2: トリガー `.willResignActive` で実機再検証（PiP ウィンドウ・音声・復帰時の PiP 終了）。
- PiP 開始のトリガー時刻（フォアグラウンド中に要求したケースのみ確認済み。`didEnterBackground`
  時点での要求が通るかは未検証）。（バックグラウンド移行時に PiP へ遷移させれば WebKit の制約上は継続再生が許可される）。
  YouTube iframe はクロスオリジンのため、ページ側から video 要素の PiP を操作できるかは未検証。
- 画面ロック時（`isSuspendedUnderLock`）の挙動は未測定（同じ制約がかかる見込み）。
