# park復帰直後のコールドステートによる操作不能

## 目的 / 仮説
ユーザー仮説「無操作でpark（スリープ）に入り、突如操作すると挙動が壊れる」の検証。park復帰と操作の競合を静的解析。

## 環境
- リポジトリ main @ 865dded。対象: `park.ts`, `app_park.go`, `player.ts`, `playback-manager.ts`, `renderer.ts`

## 結果

### 主因（採択候補）: WebView再生成でJS状態がゼロ初期化され、最初のポーリングまで1〜3秒の「コールドウィンドウ」が開く
- park は WKWebView を物理的に破棄・再生成する（`app_park.go:230,293` の `WindowUnloadWebView`/`WindowReloadWebView`）。復帰時はJSモジュール全体が再実行され、`goState`（`player.ts:77-82`）は `{currentTime:0, duration:0, isPlaying:false}` に戻る。**一方Goネイティブ再生は止まっていない**。
- `goState` を更新する唯一の手段 `startGoStatePolling()` の初回tickは `setTimeout(tick, 1000ms)`（歌詞パネル開時500ms）で遅延起動（`player.ts:384`）。同期的なシードは無い。
- この復帰直後ウィンドウ内の操作:
  - `togglePlayPause()`（`player.ts:862-878`）は `goState.isPlaying`（=false）を見て再生中に `AudioResume()` を呼ぶ → Go側no-op → **ボタン無反応**。
  - `seek(time)`（`player.ts:153-171`）は `goState.duration`（=0）でクランプし **常に0秒へシーク** → シークバーが動かない/巻き戻る。
  - `updateSeekUI` はポーリングtick内でのみ呼ばれるため、初回tickまで表示が固まる。
- 「アイドル後に突然操作すると壊れる」報告と発生条件が一致（復帰完了＝クリック可能になった瞬間が丁度コールドウィンドウ）。

### 副因: `initApp` の非await初期化チェーンと早期クリックの競合
- `renderer.ts:79-107` で `initSettings`→`initGoQueueBridge`→`restoreFromPark` が detached promise で走り、`state.playbackQueue`/`currentSongIndex` の復元（`playback-manager.ts:118-121`）前の操作はキュー依存UIが空デフォルトを参照。メタデータ/スキップ系の混乱を増幅。

### 棄却
- 「破棄済みDOMへのリスナー残留」説: WebViewごと再生成されるため該当せず。
- 既修正の `withPollTimeout`/`goPollInFlight` は旧セッションの孤児ポーリング対策であり、本件（新セッションのゼロ初期化）には効かない。

## 結論
主因は park 復帰後の**状態再水和の遅延**。修正方向: `initPlayer` 時に初回tickを遅延なしで即時実行（または `AudioGetStatus` を同期的に一度呼んで `goState` をシード）し、コールドウィンドウを閉じる。副因として初期化チェーンの await 整理も候補。

## 次の一手 / 未検証事項
- 即時シード実装後、park→復帰→即クリックの実機再現テスト。
- 副因（キュー復元前操作）の影響範囲の実測。
