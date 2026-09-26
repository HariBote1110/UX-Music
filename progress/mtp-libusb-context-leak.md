# MTP 監視の libusb コンテキストリーク修正とクラッシュ出力の保存

調査記録: `desktop_crash_research/notes/mtp-libusb-context-leak.md`

## Decision

- **libusb コンテキストの所有者を `mtp.Device` にする。** `go-mtpfs` の `SelectDevice` は
  呼ぶたびに `libusb_init` しながら `libusb_exit` を一度も呼ばず、MTP 端末が無い状態で
  毎分ポーリングすると 1 分ごとに pipe 1 組と pthread TLS キー 1 個が漏れていた。
  macOS の `PTHREAD_KEYS_MAX`（512）に約 470 回で到達し、libusb 内部の assert → abort →
  Go ランタイム経由で exit 2（起動 7h50m 後に確定的に終了）となっていた。
  - 失敗経路では候補デバイスを Close/Done したうえで `Context.Exit()` する。
  - 成功時は選ばれた `Device` がコンテキストを保持し、`Done()` で解放する
    （`Done()` は冪等・nil 安全にした）。`pkg/mtp.Manager.Dispose()` は既に Close→Done
    の順で呼ぶため、アプリ側の変更は不要。
- **Go のクラッシュ出力をファイルに残す。** `debug.SetCrashOutput` で
  `<UserData>/logs/crash.log`（macOS では `~/Library/Application Support/ux-music/logs/`）
  に追記する。起動ごとに `=== UX-Music started <時刻> pid=<pid> ===` の見出しを書く。
  Finder 起動のアプリは stderr が捨てられ、cgo 内の abort でも .ips が作られないため、
  今回は runningboardd の終了ステータスしか痕跡が無かった。

## Alternatives considered

- libusb コンテキストをプロセスで 1 個だけ作り使い回す案: 漏れは止まるが、
  `go-mtpfs` の `SelectDevice` の公開シグネチャかグローバル状態に手を入れる必要があり、
  所有権を Device に寄せる方が局所的で他の呼び出し元にも安全なため不採用。
- MTP 監視の間隔を延ばす案: 到達時間が延びるだけで根本解決にならないため不採用。

## Constraints / Gotchas

- `go test -race ./...` や .ips を見てもこの種の不具合は見つからない。長時間稼働で落ちる場合は
  `lsof -p <pid>` の FD 種別の内訳を時系列で見るのが早い。
- zsh 環境によっては `log` がシェル関数で上書きされているので、unified log は `/usr/bin/log` で引く。
- libusb の TLS キー枯渇は FD 上限より先に来る（FD は約 1000 本の時点で落ちる）。
