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

## 次の一手 / 未検証事項
- Picture in Picture（バックグラウンド移行時に PiP へ遷移させれば WebKit の制約上は継続再生が許可される）。
  YouTube iframe はクロスオリジンのため、ページ側から video 要素の PiP を操作できるかは未検証。
- 画面ロック時（`isSuspendedUnderLock`）の挙動は未測定（同じ制約がかかる見込み）。
