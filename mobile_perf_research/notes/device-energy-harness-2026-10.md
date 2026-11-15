# iPhone Air 実機の電力計測ハーネスと発熱対策 A〜E の前後比較（2026-10）

## 目的

`thermal-static-review-2026-10.md` で挙げた発熱・電池対策（A〜E）が、実機で本当に消費を減らしているかを
繰り返し測れる手順を作り、実際に 1 回、前後比較で動作を証明する。

対象の対策（ベースライン = コミット `f003476e`、「後」= main の HEAD）:

- A: Control タブの 2 秒ポーリングを「タブ選択中かつアプリ active」だけに限定
- B: 4Hz 位置タイマーは再生中のみ、Now Playing 情報は変化時のみ再発行
- C: 非表示 YouTube を低画質レイアウト固定、JS の 250ms 時刻報告は再生中のみ
- D: Now Playing の影・背景を平坦化
- E: 歌詞の 5Hz tick は再生中のみ

## 環境

- 実機: YkiPhoneAir（iPhone Air、iOS 27.0.1）。CoreDevice ID `6A208EB1-5443-557E-841D-E2963B59A5CA`、
  xctrace 用 UDID `00008150-001A55A63C07801C`（スクリプトが `devicectl list devices --json-output` から自動解決）。
  接続は Wi-Fi（transport = localNetwork）。
- Xcode 26.5。Instruments テンプレート「Power Profiler」を `--attach <pid>` で 1 プロセスに付ける。
  `--all-processes` は「Location Energy Model cannot handle a target type of 'All Processes'」で不可。
- 計測ビルドは **別バンドル ID `jp.ux-labs.UXMusicMobile.perf`**（表示名 "UXM Perf"）。TestFlight 版
  （`jp.ux-labs.UXMusicMobile`）には触れない。スクリプトは実 ID のアプリを渡すと拒否する。
  - `project.pbxproj` にプロジェクトレベルの `UXM_BUNDLE_ID_BASE`（既定は実 ID）を追加し、iOS/Watch の
    `PRODUCT_BUNDLE_IDENTIFIER` と `WKCompanionAppBundleIdentifier` をそれ経由にした。既定値のまま
    `xcodebuild -showBuildSettings` の出力が変わらないことを確認済み。
  - 署名は既存の自動署名（ワイルドカード "iOS Team Provisioning Profile: *"）でそのまま通った。
- ビルドは Debug 構成（DEBUG フックが必要）に `SWIFT_OPTIMIZATION_LEVEL=-O` を付けて最適化。前後とも同条件。
- DEBUG 場面フック（`UXMusicMobileApp.swift`、環境変数 `UXM_DEBUG_PERF_SCENARIO`）:
  `idle_control_visited` / `playing_control_visited` / `playing_control_selected` / `local_playing` /
  `local_paused` / `nowplaying_open`。`youtube_hidden` は既存の `UXM_DEBUG_YT_VIDEO`（`aqz-KE-bpKQ`）+
  `UXM_DEBUG_YT_SERVICE=1`。タブ切替は DEBUG 限定の `Notification`（`HomeRootView` が受ける）。
  音源は 10 分・44.1kHz ステレオ・振幅 0.05 の 440Hz サイン波 WAV をキャッシュに 1 回生成。
  フォアグラウンド場面では画面が勝手に消えないよう `isIdleTimerDisabled = true`。

## 手順

### 1. ビルド（前・後）

```sh
# 後: main（HEAD）
cd UX-Music-Mobile
xcodebuild -project UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile -configuration Debug \
  -destination 'id=6A208EB1-5443-557E-841D-E2963B59A5CA' -derivedDataPath /tmp/dd-after \
  SWIFT_OPTIMIZATION_LEVEL=-O UXM_BUNDLE_ID_BASE=jp.ux-labs.UXMusicMobile.perf \
  INFOPLIST_KEY_CFBundleDisplayName="UXM Perf" -allowProvisioningUpdates build

# 前: f003476e に「バンドル ID 変数化」と「DEBUG 場面フック」の 2 コミットを cherry-pick した detached worktree
git worktree add --detach /tmp/baseline-wt f003476e
git -C /tmp/baseline-wt cherry-pick <バンドルID化コミット> <場面フックコミット>
#   フックのコミットは ベースラインに存在しない UXM_DEBUG_NP_LOCAL フックの近傍で衝突する。
#   衝突は「NP_LOCAL の断片を捨てて自分の追加分だけ残す」で解決（今回もそうした）。
#   同じビルドコマンドを worktree の UX-Music-Mobile で -derivedDataPath /tmp/dd-before として実行。
```

（xcodebuild は同時に 1 つだけ。`pgrep -x xcodebuild` で待つ。）

### 2. 1 回の計測

```sh
mobile_perf_research/tools/device_energy.sh \
  --app /tmp/dd-after/Build/Products/Debug-iphoneos/UX-Music-Mobile.app \
  --scenario local_paused --label after-1 --duration 120 --settle 15
# バックグラウンド（設定アプリを前面に出す）: --background を付ける
```

処理: install → （必要なら Mac 上にスタブサーバ起動、LAN IP は既定経路のインターフェースから取得）→
`devicectl device process launch --environment-variables ...`（PID は `--json-output` から取得）→
settle → （`--background` なら `com.apple.Preferences` を起動）→ `xctrace record --template "Power Profiler"
--attach <pid> --time-limit` → `xctrace export --xpath` で 4 テーブル
（`ProcessSubsystemPowerImpact` / `ProcessQOSExecution` / `SystemPowerLevel` /
`device-thermal-state-intervals`）→ `summarise_trace.py`（`python3 -I`）で 1 行 JSON にして
`tools/out/summary.csv` に追記。トレースと生 XML は `tools/out/`（gitignore 済み）。

指標の意味:

| 列 | 意味 |
|---|---|
| cpu_pct | プロセスの CPU 時間 / 録画の実時間（`ProcessQOSExecution` の合計）。最も感度が高い |
| cpu_instr_per_s | 1 秒あたりの実行命令数（M = 百万） |
| cpu/gpu/display/net_impact | Instruments の 0〜20 の「パワーインパクト」を時間加重平均。0.1 刻みで粗く、静かなアプリではほぼ 0.0 |
| wifi_rx/tx_kb | 録画中の Wi-Fi 受信/送信量 |
| stub_requests | スタブサーバが録画中に受けた HTTP 要求数（ポーリング回数の直接証拠） |
| system_pct_per_hr | 端末全体の電池消費モデル（**充電中は 0**） |

## 結果

条件: 各 120 秒録画（settle 15 秒後）、前・後を交互実行（before, after, before, after）。
`youtube_hidden` と `nowplaying_open` は各 1 回。値は実行平均（括弧は個別値）。

| 場面（対策） | 指標 | 前 | 後 | 差 |
|---|---|---|---|---|
| `local_paused`（B）n=2 | CPU % | 0.514（0.502, 0.527） | 0.331（0.338, 0.323） | **-36%** |
| | 命令/秒 | 5.7M | 4.5M | -21% |
| `playing_control_selected` + bg（A）n=2 | スタブ要求数/120s | 65, 65 | **0, 0** | -100% |
| | Wi-Fi 受信/送信 | 55.0 / 40.4 KB | 0 / 0 KB | -100% |
| | CPU % | 1.51（1.18, 1.85） | 0.72（0.40, 1.04） | -52%（ばらつき大） |
| `playing_control_visited` + bg n=2 | CPU % | 0.93（1.03, 0.83） | 0.67（0.92, 0.41） | 重なりあり |
| | スタブ要求数 | 0, 0 | 0, 0 | （Library へ戻すので A は無関係） |
| `idle_control_visited`（前面・Library）n=2 | CPU % | 0.369（0.380, 0.359） | 0.349（0.344, 0.354） | -5%（誤差級） |
| | スタブ要求数/120s | 62, 62 | 63, 63 | 同じ（下記参照） |
| `nowplaying_open`（B/D）n=1 | CPU % | 3.15 | 2.06 | -35% |
| | 命令/秒 | 37.7M | 25.6M | -32% |
| `youtube_hidden`（C）n=1 | アプリ CPU % | 13.5 | 17.1 | 逆転（n=1、下記参照） |
| | Wi-Fi 受信 | 19.8 MB | 8.6 MB | -57% |

パワーインパクトは全場面でほぼ 0.0（`nowplaying_open` のみ CPU 0.002〜0.008）。熱状態は全 run で Nominal。

## 結論

- ハーネスは動いた。前後の差を、**スタブ要求数・Wi-Fi 量（決定的）** と **CPU 時間（感度高）** で検出できる。
  Instruments のパワーインパクト（0.1 刻み）は静かなアプリでは使えない。
- **A は実機で確認**: バックグラウンド再生中に Control タブを選択したままにすると、前は 120 秒で 65 回（約 55KB 受信 /
  40KB 送信）ポーリングを続け、後は 0 回。
- **B は有意**: 一時停止中の CPU が約 1/3 減（再現 2/2）。Now Playing 表示中も約 35% 減（n=1、方向のみ）。
- **D/E の単独効果は分離できていない**（D は `nowplaying_open` に B と混在、E は歌詞画面の場面を未実装）。
- **C は未確定**: アプリプロセスの CPU は後の方が高いが n=1 で、YouTube の映像デコードは WebContent/GPU 別プロセス側に
  あり、`--attach <アプリ pid>` では映らない。受信量が半減した点（低画質化）は C の方向と合う。
- 発見: **ベースラインでも、フォアグラウンドで Control → Library へ切り替えるとポーリングは止まっていた**
  （`idle_control_visited` の要求数は前後同数 = サイドカー用 2 秒ポーリングのみ）。iOS 27 の `TabView` は
  非選択タブで `onDisappear` を呼ぶらしく、静的レビューの想定（opacity 保持で onDisappear が来ない）はフォアグラウンドでは
  当てはまらない。A が効くのは「Control を選択したままバックグラウンド再生」の場面。

## 注意点（再現性）

- **端末は充電状態として記録されていた**（`DeviceChargingState` が録画全体を覆い、`system_pct_per_hr` と
  CPU/GPU/ネットワークのパワーインパクトが 0）。絶対的な電池消費（%/h）は取れていない。取るには充電を外して再録画が必要
  （接続は Wi-Fi なので、ケーブルを外しても `devicectl`/`xctrace` は使える）。
- 画面輝度・表示（display_impact は 0.1〜1.0 でばらつく）、Wi-Fi 状態、直前の熱の持ち越しが run 間でずれうる。
  交互実行と複数 run で緩和しているが、熱状態は全 run で Nominal だったので熱ドリフトは観測されていない。
- `--background` は設定アプリを前面にするだけ。端末が自動ロックすれば画面消灯になり、display 系の値が変わる。
- `xctrace record` は、`devicectl` を呼ばずに約 10 秒以上空くと「Timed out waiting for device to boot」で失敗する
  （Wi-Fi トンネルがアイドルになるため）。スクリプトは attach 直前に `devicectl device info processes` を 1 回呼んで回避し、
  最大 3 回リトライする。
- 録画対象はアプリ本体プロセスのみ。WebContent / GPU プロセス、音声サーバ（mediaserverd）、coreaudiod の負荷は含まれない。
- Debug 構成 + `-O` であり、リリースビルドの絶対値とは一致しない（前後比較用）。
- 初回の `local_*` 場面は音源 WAV（約 100MB）の生成が入る。2 回目以降はキャッシュを再利用する（本検証では初回生成後に計測）。

## 次の一手

1. 端末を充電から外した状態で `local_paused` / `playing_control_selected` を再録画し、`system_pct_per_hr` を取る。
2. C 用に WebContent プロセスも拾う（`--attach` を複数、または Activity Monitor / システム全体の計測）。n≥3 に増やす。
3. E 用に「歌詞画面を開いて一時停止」の場面フックを足す。D は `nowplaying_open` 再生中と一時停止で分けて測る。
4. 1 本 約 3 分なので、CI 的に回すなら before/after の `drive` スクリプト（交互・n=3）を `tools/` に足す。
