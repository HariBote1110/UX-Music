# MTP 監視の libusb コンテキストリークによる定期クラッシュ（起動 7h50m 後に exit 2）

## 目的 / 仮説
- 症状: UX Music Desktop が「定期的に」落ちる。`~/Library/Logs/DiagnosticReports` に UX-Music の .ips は無い。
- 仮説: 一定速度で何らかの資源が漏れ、上限到達で Go ランタイム経由の異常終了（exit 2）になっている。
- 反証条件: 漏れている資源が見つからない／再現プログラムで上限到達時に落ちない。

## 環境
- ホスト: Yuki の Mac mini（Apple Silicon）, macOS 26.6.2 (25G83)
- 実行中アプリ: `/Applications/UX-Music.app`（CFBundleVersion 1.0.0、バイナリ 2026-09-12 15:12 ビルド）
- Go: `go version` の出力に準拠（再現は本リポジトリの go.mod で `go build`）
- libusb バインディング: `third_party/hanwen-usb`（replace）、MTP: `third_party/go-mtpfs`（replace）

## 手順
1. 終了履歴: `/usr/bin/log show --last 7d --style compact --predicate 'process == "runningboardd" AND eventMessage CONTAINS "com.wails.UX-Music" AND eventMessage CONTAINS "termination reported"'`
   - 注意: zsh の `log` は関数で上書きされていることがあるので `/usr/bin/log` を使う。
2. 稼働中プロセスの資源: `lsof -p <pid> | awk '{print $5}' | sort | uniq -c`、pipe 本数を 2 秒間隔でポーリング。
3. 再現: `desktop_crash_research/tools/libusbleak/main.go` を `go build` し、launchd と同じ `ulimit -Sn 256` 下で実行（MTP 端末非接続）。

## 結果

### 終了履歴（runningboardd）
| PID | 起動 | 終了 | 稼働時間 | 終了ステータス |
|---|---|---|---|---|
| 23539 | 2026-09-25 03:05:55 | 2026-09-25 10:56:12 | 7h50m17s | `(0, 0, 512)` = exit 2 |
| 34773 | 2026-09-26 00:09:12 | 2026-09-26 07:59:30 | 7h50m18s | `(0, 0, 512)` = exit 2 |

稼働時間が 1 秒差で一致 → 時間比例の資源枯渇。スリープ/復帰は無し（pmset）。

### 稼働中 PID 81443（18:27:55 起動）の観測
| 時刻 | 稼働 | PIPE FD | 備考 |
|---|---|---|---|
| 21:55:28 | 3h27m | 424 | 全 424 本が同一プロセス内で相互に接続された 212 組（子プロセス用ではない） |
| 21:58:13 / 21:59:12 / 22:00:12 | – | +2 ずつ | 毎分「起動後 +17 秒」の位相で 1 組ずつ増加し解放されない |

- スレッド数 26〜28、RSS 約 116 MB で増加傾向なし。

### 発生源
- `server/app_mtp.go` `startMTPMonitor`: 5s→10s→20s→40s→60s の指数バックオフで `mtpManager.Initialize()` を呼び続ける。tick 位相は起動後 5,15,35,75,135… 秒 = 毎分 +15 秒（+監視開始までの約 2 秒で観測と一致）。
- `pkg/mtp/manager.go` `Initialize` → `gomtp.SelectDevice("")`
- `third_party/go-mtpfs/mtp/select.go:135` `SelectDevice` が毎回 `usb.NewContext()`（`libusb_init`）を呼ぶが、**どの経路でも `Context.Exit()`（`libusb_exit`）を呼ばない**。端末無しなら "no MTP devices found" で即 return し、コンテキストが丸ごと漏れる。
- libusb コンテキスト 1 個につき: イベント通知用 pipe 1 組（FD 2 本）＋ `pthread_key_create` による TLS キー 1 個。

### 再現（libusbleak）
| 項目 | 値 |
|---|---|
| 1 回あたりの FD 増加 | +2（正確に一定） |
| 死亡時の呼出回数 | 508 回目（FD 1027） |
| 終了 | `Assertion failed: (pthread_key_create(key, ((void*)0)) == 0), function usbi_tls_key_create, file threads_posix.h` → `SIGABRT` / `signal arrived during cgo execution` → **exit 2** |
| スタック | `hanwen/usb.NewContext` ← `go-mtpfs/mtp.SelectDevice` (select.go:135) |

## 結論
- **仮説採用。** 直接原因は FD 上限ではなく **pthread TLS キー枯渇**（macOS `PTHREAD_KEYS_MAX` = 512）。
- 実アプリでは WebKit/AppKit 等が先に TLS キーを消費するため、単体再現の 508 回より少ない約 470 回（= 470 分 ≈ 7h50m）で到達し、観測と一致。
- abort は cgo 実行中のため Go ランタイムがシグナルを拾って exit 2 で終了し、macOS のクラッシュレポート（.ips）が生成されない。stderr もどこにも保存されていないため、痕跡は runningboardd の終了ステータスのみ。
- MTP 端末を繋いでいない通常利用で必ず発生する（端末接続中は `Initialize` が呼ばれないので進行しない）。

### 棄却済み・無関係と判断したもの
- `~/Library/Logs/DiagnosticReports` の Python クラッシュ多数: KiCad 同梱 Python（親は codex/bash）で UX-Music とは無関係。
- データ競合: `go test -race ./...` で DATA RACE 検出なし（`server` の `TestSyncContactRecoversAndPersistsStalePeerPort` 失敗は同期ポート復旧のロジック不一致でクラッシュとは無関係）。
- スリープ/復帰契機: 両時刻とも該当なし。

## 次の一手 / 未検証事項
- 修正（/development の TDD で実施）:
  1. `SelectDevice` の失敗経路で `c.Exit()` を呼ぶ。成功時は Device にコンテキストを持たせ、`Dispose`（Close/Done）で `Exit()` する。
  2. もしくは MTP 監視で libusb コンテキストをプロセスで 1 個だけ生成して使い回す。
  3. 回帰テスト: 端末無しで `Initialize` を N 回呼んでも FD（pipe）数が増えないこと。
- 恒久対策: `debug.SetCrashOutput` で Application Support 配下にクラッシュ出力を保存する（今回 stderr が失われ調査が遠回りになった）。
- 端末接続中に抜き差しを繰り返した場合（Dispose→Initialize）も同様に漏れるはずだが未計測。
