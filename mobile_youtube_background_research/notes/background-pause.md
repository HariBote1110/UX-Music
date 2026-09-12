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

### G-2: トリガー `.willResignActive` で実機再検証（G-1 と同じ手順）

| 時刻 | 観測 |
| :--- | :--- |
| 20:17:20.07 | 原因不明の `paused`（ユーザー操作の可能性） |
| 20:17:24.90 | 2 回目の `ready`（ページが再読み込みされ PiP フレーム情報がリセット。原因未特定） |
| 20:17:25.01 | `willResignActive` → `failed reason=unavailable`（フレーム未検出のため）→ `didEnterBackground` でフォールバック |
| 20:17:29.48 | `willResignActive` → `entering` |
| 20:17:29.48 | **7 ms 後に `failed`**（JS 側の `webkitSetPresentationMode` 要求が受理されない） |
| 20:17:29.53〜29.59 | WebKit のモードが `picture-in-picture` に **53 ms だけ**切り替わり自動で `inline` に戻る（こちらからの exit 要求ログなし） |
| 20:17:30.34 | `didEnterBackground` → フォールバック（一時停止＋復帰時再開） |

- ユーザー目視: PiP ウィンドウは出ず、音も止まった。
- 53 ms だけのモード切り替えはシミュレータ（PiP 非対応）での挙動と同型で、システム側で PiP 開始が中断されている。
- 結論（暫定）: **B-4（アプリが完全にアクティブな間の要求）は成功するが、非アクティブ化・バックグラウンド化の
  遷移中に出したコードからの PiP 要求は通らない。** ライフサイクル通知をトリガーにした自動 PiP は
  この方式では成立しない。
- 未確認: 今回のバックグラウンド化は `devicectl` で設定アプリを前面に出す方法で、ユーザーのホームスワイプとは
  経路が異なる。実際のホームスワイプで挙動が変わるかは未検証。

### G-3: 実機でユーザーが手動ホームスワイプ（トリガー `.willResignActive`、G-2 と同じビルド）
手順: `devicectl device process launch --terminate-existing --console --environment-variables
'{"UXM_DEBUG_YT_VIDEO":"aqz-KE-bpKQ","UXM_DEBUG_YT_SERVICE":"1"}'` で起動しログを 4 分記録。
再生開始後、ユーザーが画面下端から上へスワイプしてホーム画面へ。

| 時刻 | 観測 |
| :--- | :--- |
| 20:19:40.70 | `playing` |
| 20:20:04.773 | `willResignActive` → `entering` |
| 20:20:04.806 | `entered`（モードが `picture-in-picture` に） |
| 20:20:04.810 | `failed`（JS 側の要求は不受理） |
| 20:20:04.834 | `exited`（`entered` の **28 ms 後**、こちらからの exit 要求なし） |
| 20:20:05.93 | `paused` → `didEnterBackground` → フォールバック |

- ユーザー目視: PiP ウィンドウは出ず、音も止まった。
- フレーム検出は正常（`unavailable` ではない）。G-2 と同じく、システムが PiP 開始を数十 ms で中断している。
- 結論: **実際のホームスワイプでも、アプリが前面から離れる遷移中にコードから出した PiP 要求は拒否される（棄却済み）。**
  ライフサイクル通知（`willResignActive` / `didEnterBackground`）を起点にした自動 PiP はこの方式では成立しない。
  成立を確認できているのは、アプリが完全にアクティブな間に PiP を開始する経路（B-4）のみ。
- 実装上の気付き: `entered` の直後に `failed` が記録されており、`enterPictureInPicture()` の成否判定
  （JS の戻り値）とモード変更イベントの順序が食い違うことがある。

## 仮説C: フルスクリーン表示中の動画ならホームスワイプで自動 PiP になる（ユーザー判断で追加調査）
- 前提: Safari では全画面表示中の動画だけが、ホームスワイプで自動的に PiP へ移る
  （インライン動画は自動 PiP にならない）。WKWebView の WebKit も同じ経路を持つはず。
- 手段: アプリがアクティブな間に、YouTube フレームの `video` に対してネイティブから
  `webkitEnterFullscreen()` を呼んで全画面表示にし、その状態でユーザーがホームスワイプする。
- 変数を 1 つに絞るため、ホスト直結モード（`UXM_DEBUG_YT_SERVICE` なし）で実行し、フェーズG の
  ライフサイクル処理（`MusicPlayerService` は現在曲なしのため何もしない）を関与させない。
  無音にならないよう、このモードでだけ `.ready` で `unmute` を送る。
- 棄却条件: (1) 全画面にならない、(2) 全画面からホームスワイプしても `picture-in-picture` に移らない、
  (3) 移っても再生・音声が続かない。

### C-1: 実機で全画面表示 → ユーザーが手動ホームスワイプ
手順: `verify_fullscreen_device.sh`（検証時は scratchpad）。ホスト直結モードで
`{"UXM_DEBUG_YT_VIDEO":"aqz-KE-bpKQ","UXM_DEBUG_YT_FULLSCREEN":"1"}` を渡して起動し、`--console` で 5 分記録。
再生 5 秒後にネイティブから YouTube フレームの `video.webkitEnterFullscreen()` を呼び、全画面になったら
ユーザーがホームスワイプ。

| 時刻 | 観測 |
| :--- | :--- |
| 20:23:22.29 | `playing`（`muted=0`、音あり） |
| 20:23:27.92 | `webkitEnterFullscreen()` 要求（戻り値時点では `displayingFullscreen=false`） |
| 20:23:27.97 | `webkitpresentationmodechanged` / `webkitbeginfullscreen` → `mode=fullscreen` |
| 20:23:59.05 | ホームスワイプでアプリが `inactive`（`mode=fullscreen`、再生中） |
| 20:23:59.51 | **自動で `mode=picture-in-picture`**（`webkitendfullscreen` 同時発火） |
| 20:23:59.57 | `didEnterBackground` |
| 20:24:01〜08 | バックグラウンドの PiP 中も `t=38→45` と進行、`paused=0` |
| 20:24:08.10 | `pause`（ユーザーが PiP ウィンドウを閉じた・止めたと確認済み）→ 20:24:08.93 `mode=inline` |
| 20:24:14.03 | フォアグラウンド復帰 |

- ユーザー目視: PiP ウィンドウが出て、音も続いた。
- 結論: **仮説C は実機で成立。** YouTube フレームの `video` をネイティブから全画面にしておけば、
  ホームスワイプで WebKit が自動的に PiP へ移し、バックグラウンドでも音声付きで再生が続く。
  コードからの PiP 要求（G-1〜G-3）と違い、システム自身の自動遷移なので拒否されない。

## 方式の再考（ユーザー要望: 「滑らかにバックグラウンド再生に移行したい」）
C-1 の結果（全画面を経由すれば自動 PiP になる）を受けて、ユーザーは全画面ボタン等の操作を挟む形を望まず、
ホームスワイプ・画面ロックだけで途切れず音が続く形を求めた。WKWebView 内の経路（A〜C）に加え、
リポジトリ既存の LAN 中継経路を候補 D として整理する（コード読解のみ、未実測）。

### 候補D: PC の公式再生を LAN 中継して iPhone では音声ストリームとして鳴らす
- デスクトップ側は本番配線済み: `server/app_remote_relay_notify.go` がプロセスタップ
  （`pkg/audio.ProcessTapCapture`）の PCM を入力に `remoteRelay.Start` を呼び、
  `GET /v1/remote/relay`（ADTS AAC-LC 256kbps、chunked、認証必須、GUI モード限定、非アクティブ時 409）で配信。
- `POST /v1/remote/command`（`action: "play-song"`）で PC に特定曲を再生させられる（`progress/remote-play-song.md`）。
- TV は `play-song` 送信 → `GET /v1/remote/state` の `relay.active` を 0.5 秒間隔・最大 10 秒待機 →
  `TVRelayStreamPlayer`（専用 `AVAudioEngine`）で受信、というフローが完成済み（`progress/tvos-relay-reception.md` 2026-08-13 追記）。
- iPhone 側: `TVRelayStreamPlayer` / `TVAACDecoder` / `ADTSFrameParser` は **iOS アプリのターゲットにもビルド済み**、
  `RemoteAPIClient.sendPlaySongCommand(songId:)` と `relayRequest()` も存在。iPhone から使う画面・サービスが未配線なだけ。
- 期待: iPhone では通常の音声ストリーム再生になるため、`UIBackgroundModes=audio` でホームスワイプ・画面ロックでも途切れない見込み（未実測）。
- 制約: PC で GUI 版が起動していて LAN 上にいること（ヘッドレス `--serve` では 404）。映像は PC 側のみ。
  放送型で PC の再生と連動し、クライアントごとに別曲は不可（`project_youtube` の既定方針どおり）。
  PC 無し・外出先では使えないため、その場合は PiP / 一時停止＋復帰へのフォールバックが必要。

### WebKit の公開仕様と YouTube 規約の調査（2026-09-12、Web 調査＋原文確認）
WebKit / Apple 側（読み取り専用サブエージェントによる調査。WebKit ソースの該当行までは未特定）:
- WKWebView のインライン `<video>` から、ユーザー操作なしで自動 PiP にする公開 API はない（Apple DTS のフォーラム回答）。
  `AVPlayerViewController.canStartPictureInPictureAutomaticallyFromInline` は AVPlayerViewController ベースの再生専用で、
  WebKit のインライン再生には効かない。自動 PiP は全画面からの遷移時のみ（C-1 の実測と一致）。
- `UIBackgroundModes=audio`＋`.playback` でも WKWebView 内のメディアはバックグラウンドで止まる、という報告が
  iOS 13 以降繰り返しある（WebKit Bugzilla #203293 など）。継続するのは PiP 中・AirPlay 中などの例外のみ。

YouTube API 規約（原文を WebFetch で確認）:
- Developer Policies III.I.9: 「create, include, or promote features that play content…from a background player」→ **禁止**。
- Developer Policies III.I.7: 「separate, isolate, or modify the audio or video components」→ **禁止**。
- Developer Policies III.I.6: プレイヤーの一部・機能の改変・ブロックを禁止。PiP 自体への明記はない。
- Required Minimum Functionality: 「Embedded players must have a viewport that is at least 200px by 200px.」、
  プレイヤー前面へのオーバーレイ禁止、自動再生はプレイヤーが表示され半分以上見えている場合のみ。

規約から見た各方式の位置付け（解釈。法的判断ではない）:
| 方式 | 規約上の懸念 |
| :--- | :--- |
| プレイヤーを見せずにバックグラウンドで音声継続（WebKit 延命・非公開設定） | III.I.9 に正面から該当 |
| 候補D: PC の再生音をタップして iPhone へ音声のみ中継 | III.I.7（音声の分離・抽出）に該当する可能性が高い |
| PiP（システムの PiP ウィンドウにプレイヤーが表示されたまま再生） | 明記なし。プレイヤーは可視だがグレー |
| 既存の非表示パーキング（画面外・alpha 0.01・256x144pt） | RMF の最小 200x200・可視要件に反する可能性 |
| 既存の低画質化（WebView を約 85x48pt に縮小して拡大表示） | RMF の最小 200x200 に反する可能性 |

### ユーザー判断（2026-09-12）
- **YouTube API 規約は考慮しない。法律上問題がなければ可。** 既存のパーキング・低画質化の規約懸念は「後で決める」。
- プロジェクト原則（法律とクリエイター還元を守る）は維持するため、公式 embed を経由しない抽出再生（yt-dlp 等）は候補から外す。

この基準で「滑らかなバックグラウンド再生」の候補を絞ると:
| 候補 | 滑らかさ | 前提・リスク |
| :--- | :--- | :--- |
| D: LAN 中継（PC の公式再生音声を iPhone で音声ストリーム再生） | ホームスワイプ・ロックで途切れない見込み | PC の GUI 版起動が必須。配線はほぼ既存 |
| E: WebKit の非公開設定でバックグラウンドの動画停止を外す | 単体で途切れない見込み | 設定の存在自体が未確認。App Store 審査・OS 更新で壊れるリスク |
| PiP（全画面経由の自動 PiP / 手動 PiP ボタン） | 操作を挟むので滑らかではない | 実機で成立済み（B-4 / C-1） |

### WebKit ソース調査（読み取り専用サブエージェント、GitHub WebKit main）
- **ソース確認済み**: `Source/WebCore/platform/audio/ios/MediaSessionManagerIOS.mm` の `resetRestrictions()` が
  iOS のメディア種別ごとに制限を付与する。
  - `MediaType::Video` → `BackgroundProcessPlaybackRestricted`（バックグラウンドで停止）
  - `MediaType::WebAudio` → `BackgroundProcessPlaybackRestricted`
  - `MediaType::VideoAudio` → `SuspendedUnderLockPlaybackRestricted`（**画面ロック中のみ**停止）
- **ソース確認済み**: バックグラウンド遷移時は `PlatformMediaSession::beginInterruption(EnteringBackground)` が発火し、
  `client().shouldOverrideBackgroundPlaybackRestriction(type)` が true のセッションだけ停止を免れる。
  `HTMLMediaElement` の実装は WebXR immersive・CarPlay・フルスクリーン中の PiP・音声 MediaStreamTrack などで true（要約経由、全文未確認）。
- 停止条件を外す公開・非公開の設定キーは見つからなかった（`UnifiedWebPreferences.yaml` に該当なし。
  ページ可視性系の制限は `MediaElementSession` 内のビットマスクとしてハードコード）→ **候補E は見込み薄**。
- 推測: `HTMLMediaElement` のメディア種別は「映像あり＋音声あり＋ミュートでない」なら `VideoAudio`、
  映像ありでミュートなら `Video`（要確認）。

### これまでの測定の見直し（重要）
- ベースライン・V1・V2（シミュレータ）、B-1〜B-4、C-1 のホスト直結モードは、`unmute` が送られず**ミュートのまま**だった
  → `Video` 扱いでバックグラウンド停止の対象だった可能性がある。
- G-1〜G-3・フェーズF のシミュレータ検証は unmute 済みだが、バックグラウンド移行直後に**自前のフォールバックで pause を送っていた**。
- つまり「ミュートでない YouTube 動画を、何も介入せずにバックグラウンドへ回す」ケースは**一度も測定していない**。

## 仮説F: ミュートを解除した動画は `VideoAudio` 扱いになり、バックグラウンドでも止まらない
- 期待: PiP・全画面・非公開設定なしで、ホームスワイプだけで再生が続く（画面ロック時のみ停止）。
- F-1（実機・1変数）: ホスト直結モード（フェーズG のライフサイクル処理が作動しない）で `.playback` セッションを有効化し、
  `.ready` で `unmute` を送る。20 秒再生 → 設定アプリを前面へ → 25 秒観察 → 復帰。
  基準は V1（セッション有効・ミュート → 停止）。違いは unmute のみ。
- 棄却条件: バックグラウンド移行後に `time` イベントの再生位置が進まない、または `paused` が来る。

### F-1: 実機・ホスト直結モード・`.playback` セッション有効・`.ready` で unmute（1変数: unmute）
手順: `{"UXM_DEBUG_YT_VIDEO":"aqz-KE-bpKQ","UXM_DEBUG_YT_SESSION":"1","UXM_DEBUG_YT_UNMUTE":"1"}` で
`devicectl device process launch --console`、20 秒後に設定アプリを前面へ、25 秒後に復帰。
（1 回目の実行は端末ロック中で `Locked` により起動失敗し無効。ロック解除後に再実行した結果を記録。）

| 時刻 | 観測 |
| :--- | :--- |
| 20:46:25.19 | `.playback` セッション有効化 |
| 20:46:25.86 | `ready` → unmute 送信 |
| 20:46:26.45 | `playing`（ユーザーにも音が聞こえていた） |
| 20:46:45.55 | `didEnterBackground` |
| 20:46:45.79 | **0.24 秒後に `paused`**、以後 `time` は 19.04 秒のまま |
| 20:47:10.63〜 | フォアグラウンド復帰後も停止のまま（自動再開なし） |

- ユーザー目視（耳）: 設定アプリに切り替わった瞬間に音が止まった。
- 結論: **仮説F は棄却済み。** 音声ありで再生中の YouTube iframe の `video` も、バックグラウンド移行直後に WebKit が停止する。
  メディア種別による免除（`VideoAudio`）は、この経路では効いていない（ページ非表示による停止など、別の条件が働いている可能性。原因箇所は未特定）。

## 総括: WKWebView 内でのバックグラウンド再生の経路
| 経路 | 結果 |
| :--- | :--- |
| インラインのまま継続（ミュート・非ミュート、セッション有効化） | 不可（ベースライン・V1・F-1） |
| バックグラウンド中に play 再送 | 不可（V2） |
| アクティブ中にコードから PiP 開始 → その後バックグラウンド | 可（B-4） |
| 遷移中（`willResignActive` / `didEnterBackground`・実スワイプ）にコードから PiP 開始 | 不可（G-1〜G-3） |
| 全画面表示中にホームスワイプ → システムの自動 PiP | 可（C-1） |
| 停止条件を外す公開・非公開の設定 | 見つからず（WebKit ソース調査） |

→ **操作なしで滑らかに続ける経路は WKWebView 内には無い。** 滑らかさを求めるなら、WKWebView の外で音を鳴らす
候補D（LAN 中継）しか残らない。単体で動く経路は PiP 系（全画面経由の自動 PiP・手動 PiP ボタン）のみ。

### ユーザー判断（2026-09-12）: iPhone 単体で完結させたい → まず非公開フラグを試す
- PiP 系で作る前に、候補E（WebKit の非公開設定でバックグラウンド停止を外す）の実在を実機で確認する。
- App Store 審査・OS 更新で壊れるリスクは承知の上（法律上の問題はない）。

## 仮説E: WebKit の非公開フィーチャーフラグ／SPI にバックグラウンド停止を外すものがある
- E-1（列挙のみ・挙動変更なし）: 実機で `WKPreferences._features`（`_WKFeature` の key / name / 既定値 / 現在値）と、
  `WKPreferences` / `WKWebViewConfiguration` の非公開メソッド名を書き出し、
  background / suspend / lock / visib / pip / picture / media / playback / audio / video / fullscreen / nowplaying / interrupt
  を含むものに絞る。デバッグフック `UXM_DEBUG_WEBKIT_FEATURES=1`（検証後に撤去）。
- 棄却条件: 該当しそうなキー・メソッドが一つも無い。
- 候補が見つかれば E-2 以降で 1 フラグずつ切り替え、F-1 と同じ手順（ホスト直結・セッション有効・unmute）で
  バックグラウンド移行後も `time` が進むかを見る。

### E-1: 実機（YkiPhoneAir）で非公開フィーチャーフラグ・SPI を列挙
手順: `dump_webkit_features_device.sh`（検証時は scratchpad）。`{"UXM_DEBUG_WEBKIT_FEATURES":"1"}` で起動し、
`WKPreferences._features`（613 件）と `WKPreferences` / `WKWebViewConfiguration` の `_` 始まりセレクタをキーワードで絞り込み。

バックグラウンド停止に関係しそうな候補（`default` = WebKit 既定値、`enabled` = このアプリの WKWebView での現在値）:
| キー / セレクタ | default | enabled | 見立て |
| :--- | :--- | :--- | :--- |
| `InterruptVideoOnPageVisibilityChangeEnabled` | 1 | **1** | ページ非表示で動画を中断。**最有力** |
| `InterruptAudioOnPageVisibilityChangeEnabled`（`_setInterruptAudioOnPageVisibilityChangeEnabled:`） | 1 | **0** | 音声版は WKWebView で既にオフ。動画版だけオンという差が実測（ミュート有無に関係なく動画は止まる）と合う |
| `PageVisibilityBasedProcessSuppressionEnabled`（`_setPageVisibilityBasedProcessSuppressionEnabled:`） | 1 | 1 | ページ非表示で WebContent プロセスを抑制 |
| `ShouldDropNearSuspendedAssertionAfterDelay` | 1 | 1 | 一定時間後にプロセスを完全サスペンド |
| `ShouldTakeNearSuspendedAssertions` | 0 | 0 | バックグラウンドの WebContent に NearSuspended アサーション |
| `RequiresPageVisibilityToPlayAudio`（`_setRequiresPageVisibilityToPlayAudio:`） | 0 | 0 | 既にオフ |
| `_setCanShowWhileLocked:`（`WKWebViewConfiguration`） | - | - | ロック中表示。ロック時（`SuspendedUnderLock`）の検証候補 |

- 結論: 棄却条件（候補ゼロ）は不成立。E-2 以降で 1 キーずつ実測する。

### E-2: F-1 の条件＋`InterruptVideoOnPageVisibilityChangeEnabled` をオフ（1変数）
手順: `verify_wk_feature_bg_device.sh e2 InterruptVideoOnPageVisibilityChangeEnabled`（検証時は scratchpad）。
ホストの `webView.configuration.preferences` に `-[WKPreferences _setEnabled:NO forFeature:]` を読み込み前に適用。

| 時刻 | 観測 |
| :--- | :--- |
| 20:53:43.22 | `set feature key=InterruptVideoOnPageVisibilityChangeEnabled enabled 1 -> 0`（読み戻しで反映確認） |
| 20:53:43.90 | `ready` → unmute 送信 |
| 20:53:44.14 | `playing` |
| 20:54:03.97 | `didEnterBackground` |
| 20:54:04.17 | **0.2 秒後に `paused`**、以後 `time` は 19.85 秒のまま |
| 20:54:28.92〜 | フォアグラウンド復帰後も停止のまま |

- ユーザーは離席中で耳での確認なし（ログのみで判定）。
- 結論: **E-2 は棄却済み。** ページ可視性による動画中断をオフにしても停止は変わらない。
  `paused` が移行直後（0.2 秒）に来ることから、プロセスの抑制・サスペンドではなく、メディアセッションの
  バックグラウンド割り込み（`BackgroundProcessPlaybackRestricted` 系）が効いていると見られる。ソース調査上、
  この制限を外す設定キーは無いため、`PageVisibilityBasedProcessSuppressionEnabled` などプロセス抑制系の候補は優先度を下げる。
- 注意: 設定の読み戻しは WKPreferences 上の値であり、WebContent プロセスへの反映までは直接確認していない
  （読み込み前に設定しているので反映されている見込み）。

### E-3（予定）: F-1 の条件＋`navigator.audioSession.type = 'playback'`（公開 Web API、1変数）
- E-1 のダンプで `DOMAudioSessionEnabled=1`（Audio Session API 有効）。ページ自身の音声セッション種別を
  `playback` にすると、WebKit 側のメディアの扱いが変わる可能性がある。非公開 API ではないので審査・OS 更新リスクは無い。
- 手段: 全フレームに文書開始時点で注入するスクリプトで `navigator.audioSession.type = 'playback'` を設定し、
  フレームごとの読み戻し値と origin をネイティブへ報告。デバッグフック `UXM_DEBUG_WK_AUDIOSESSION_PLAYBACK=1`。
- 棄却条件: YouTube フレームで `type` が `playback` にならない、またはバックグラウンド移行後に `paused` が来る。

### E-3: F-1 の条件＋全フレームで `navigator.audioSession.type = 'playback'`（1変数）
手順: `verify_wk_feature_bg_device.sh e3 "" '"UXM_DEBUG_WK_AUDIOSESSION_PLAYBACK":"1"'`（検証時は scratchpad）。

| 時刻 | 観測 |
| :--- | :--- |
| 20:57:08.57 | メインフレーム（`http://127.0.0.1:<port>`）: `supported=1`、代入後 `type=playback` |
| 20:57:08.76 | **YouTube フレーム（`https://www.youtube.com`）: `supported=1` だが代入後も `type=auto`** |
| 20:57:09.20 | `playing` |
| 20:57:29.02 | `didEnterBackground` |
| 20:57:29.26 | **0.24 秒後に `paused`**、以後 `time` は 19.86 秒のまま（復帰後も停止） |

- 結論: **E-3 は棄却済み。** メインフレームを `playback` にしても停止は変わらない。
  クロスオリジンの YouTube iframe では `navigator.audioSession.type` の代入が反映されない（`auto` のまま）ため、
  動画を持つフレーム自体への適用はこの経路では不可能。

## 総括（iPhone 単体）
公開 API・非公開フィーチャーフラグ（E-2）・公開 Web API（E-3）のいずれでも、WKWebView 内の YouTube iframe の
`video` はバックグラウンド移行の約 0.2 秒後に停止した。停止は移行直後に来るため、プロセス抑制ではなく
メディアセッションのバックグラウンド割り込みによるもので、ソース上もこれを外す設定は見つかっていない。
→ **iPhone 単体で、プレイヤーを表示せず操作なしに音声だけ継続させる経路は、今回調べた範囲では存在しない。**
単体で継続できるのは PiP 系（B-4 のアクティブ中の PiP 開始、C-1 の全画面からの自動 PiP）のみ。
残る候補の優先度が低いもの（未検証）: `PageVisibilityBasedProcessSuppressionEnabled` などプロセス抑制系、AirPlay 出力中の免除。

### ユーザー最終判断（2026-09-12）: PiP で作る（iPhone 単体）
- 全画面ボタンを追加し、全画面中のホームスワイプでシステムの自動 PiP（C-1）に乗せる。
- インライン表示中は既存の PiP ボタンでアクティブ中に PiP を開始（B-4）。
- どちらも使わずに離れた場合は一時停止＋フォアグラウンド復帰時に再開（フェーズF のフォールバック）。
- ライフサイクル通知起点の PiP 要求（G-1〜G-3 で拒否された処理）は削除する。
- 本実装の設計判断は `progress/mobile-youtube-embed.md` フェーズH に記録。

### H-1: 本実装（フェーズH、コミット a455eb0c / 6e71b317）を実機で検証 — 全画面経由
手順: `verify_phase_h_device.sh fullscreen`（検証時は scratchpad）。`UXM_DEBUG_YT_SERVICE=1`（unmute される本番経路）＋
`UXM_DEBUG_YT_FULLSCREEN=1`（再生 6 秒後に `MusicPlayerService.enterYouTubeFullscreen()`）。20 秒後に設定アプリを前面へ、約 25 秒後に復帰。

| 時刻 | 観測 |
| :--- | :--- |
| 21:14:05.60 | `playing` |
| 21:14:10.81 | `entering fullscreen` → **1 ms 後に `fullscreen failed`** → 21:14:10.87 `fullscreen entered` |
| 21:14:25.05 | バックグラウンド移行とともに**自動で `PiP entered`**（`fullscreen exited`）→ `background decision=keepPlaying mode=pictureInPicture` |
| 21:14:25〜49 | バックグラウンドの PiP 中も `time` が 17.8 → 42.0 秒と進行（`isPlaying=1`） |
| 21:14:49.91 | フォアグラウンド復帰 → `exiting reason=foreground` → `PiP exited` |
| 21:14:49.96 | **PiP 終了直後に `paused`、以後 44.5 秒で停止したまま** |

- ユーザー目視（耳）: 設定アプリの上に PiP ウィンドウが出て、音も続いた。
- 結論: **全画面経由の自動 PiP によるバックグラウンド継続は本実装でも成立。**
- 問題1: **アプリに戻ると再生が止まる。** PiP を終了してインラインへ戻すと WebKit が一時停止し、再開要求を送っていない。
- 問題2: `enterFullscreen()` が JS の戻り値を先に受けて失敗扱い（`fullscreen failed`）にしてから、モード変更イベントで
  成功が届く（G-3 の PiP と同じ順序の食い違い）。実害はないが戻り値・ログが誤る。

### H-2: 本実装を実機で検証 — フォールバック（全画面・PiP なし）
手順: `verify_phase_h_device.sh fallback --no-build`（検証時は scratchpad）。`UXM_DEBUG_YT_SERVICE=1` のみ。

| 時刻 | 観測 |
| :--- | :--- |
| 21:15:04.25 | `playing` |
| 21:15:23.85 | `background decision=fallback mode=inline` → `fallback used: pause and resume on foreground`（`isPlaying=0`） |
| 21:15:24.09 | `paused`（位置 19.62 秒） |
| 21:15:49.04 | フォアグラウンド復帰 → `buffering` |
| 21:15:50.21 | `playing`、以後 22.7 → 25.7 秒と進行 |

- ユーザー目視（耳）: 設定アプリに切り替わると音が止まり、UX Music に戻ると続きから鳴り始めた。
- 結論: **フォールバック（一時停止＋復帰時再開）は本実装で期待通り。**

### H-3: H-1 の問題1・2 の修正（コミット 14d34495）を実機で再検証 — 全画面経由
手順: H-1 と同じ（`verify_phase_h_device.sh fullscreen`）。

| 時刻 | 観測 |
| :--- | :--- |
| 21:30:26.48 | `entering fullscreen` → `fullscreen JS request result=nil` → 21:30:26.54 `fullscreen entered`（**偽の `fullscreen failed` は出ない**） |
| 21:30:41.26 | バックグラウンド移行で自動 `PiP entered` → `background decision=keepPlaying mode=pictureInPicture` |
| 21:30:42〜21:31:03 | バックグラウンドの PiP 中も `time` が 20.8 → 42.0 秒と進行 |
| 21:31:06.23 | フォアグラウンド復帰 → `exiting reason=foreground` → 21:31:06.27 `PiP exited` |
| 21:31:06.29 | WebKit の `paused` |
| 21:31:06.48 → 06.63 | `buffering` → **`playing`（停止から約 0.35 秒で再開）**、以後 44.9 → 54.0 秒と進行 |

- ユーザー目視（耳）: 戻ったときに一瞬止まって、すぐ再開した。
- 結論: **問題1・2 とも解消。** PiP からインラインに戻る際の一瞬の停止（約 0.35 秒）は、WebKit が PiP 終了時に
  必ず一時停止するため残るが、自動で再開する。

### H-4: 実機で Now Playing の PiP ボタン → ホームスワイプ（ユーザー手動操作）
手順: `verify_manual_device.sh pipbutton 150 --no-build`（検証時は scratchpad）。`UXM_DEBUG_YT_SERVICE=1` ＋
`UXM_DEBUG_YT_OPEN_NOW_PLAYING=1` で起動し、ユーザーが PiP ボタンを押してホームへスワイプ、10 秒後に復帰。

| 時刻 | 観測 |
| :--- | :--- |
| 21:31:33.43 | `opened Now Playing` |
| 21:31:34.52 | `playing` |
| 21:32:22.81 | `background decision=fallback mode=inline` → 一時停止（1.5 秒後に復帰・再開） |
| 21:32:27.39 | 同じく `fallback mode=inline` → 一時停止（1.2 秒後に復帰・再開） |

- ユーザー目視: ホームに戻ったら止まった。
- **PiP ボタンの処理が一度も呼ばれていない**（`entering` / `PiP JS request` / `unavailable` / `PiP entered` のいずれのログも無い）。
  バックグラウンド移行時の mode は 2 回とも `inline`。ボタンの表示・タップの到達のどちらに問題があるか切り分け中。

### H-5: 利用可否の診断ログ付きで Now Playing の PiP ボタンを再検証（ユーザー手動操作）
手順: `verify_manual_device.sh pipbutton2 180`（検証時は scratchpad、診断ログ入りで再ビルド）。
診断ログ: `[UXM_YT_PIP] report ...`（ホストが受け取った hasVideo / mode / supportsPiP / supportsFullscreen）と
`[UXM_YT_PIP] availability ...`（サービス側の算出結果）。

| 時刻 | 観測 |
| :--- | :--- |
| 21:37:07.38 | `opened Now Playing` |
| 21:37:07.5〜07.97 | メインフレーム・中間フレームは `hasVideo=0` |
| 21:37:08.83 | YouTube フレーム `hasVideo=1 mode=inline supportsPiP=1 supportsFullscreen=1` → `availability ... service(pip=1 fullscreen=1)` |
| 21:37:32.07 | `entering trigger=user toggle`（**PiP ボタンのタップが届いた**）→ `PiP JS request result=nil` |
| 21:37:32.14 | `PiP entered`（偽の失敗なし） |
| 21:37:34.09 | `PiP exited`（こちらからの終了要求ログなし。ユーザー操作またはシステムによる復帰） |
| 21:37:36.28〜38.77 | 全画面の開始・終了（ユーザー操作） |
| 21:37:48〜21:40:05 | インラインで再生継続（`time` 26 → 162 秒） |

- ユーザー回答: 「ボタン 2 つ、PiP で音が続いた」。
- **ただし記録中に `didEnterBackground` は一度も無い**（アプリはバックグラウンドへ移っていない）。
  「PiP ボタン → ホームで継続」はこの記録では確認できていない。ユーザーに確認したところ**ホームへは戻っていなかった**
  （PiP・全画面を試しただけ）。「PiP で音が続いた」はアプリが前面のままの再生だった。
- 結論: PiP ボタンの表示条件（利用可否の算出）とタップ → PiP 開始は正常。H-4 でボタンが見えなかった原因は再現せず不明。

## 次の一手 / 未検証事項
- 「PiP ボタン → ホームで継続」の実機確認（H-5 ではバックグラウンド移行が記録されず未確認）。
- H-4 でボタンが見えなかった原因（再現せず）。
- 画面ロック中（PiP 継続中のロック）の挙動。
- 画面ロック中（PiP 継続中のロック）の挙動は未検証。
- 20:24:08 の一時停止の原因（ユーザーが PiP ウィンドウを操作したか）。
- 20:17:24（G-2）のページ再読み込みの原因。
- PiP 開始のトリガー時刻（フォアグラウンド中に要求したケースのみ確認済み。`didEnterBackground`
  時点での要求が通るかは未検証）。（バックグラウンド移行時に PiP へ遷移させれば WebKit の制約上は継続再生が許可される）。
  YouTube iframe はクロスオリジンのため、ページ側から video 要素の PiP を操作できるかは未検証。
- 画面ロック時（`isSuspendedUnderLock`）の挙動は未測定（同じ制約がかかる見込み）。
