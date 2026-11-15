# MTP 端末検知の libusb ホットプラグ化

## Decision

- macOS / Linux では MTP 端末の検知をポーリングから libusb のホットプラグ通知に置き換えた。
  - 取り込み済みの libusb v1.0.30 は darwin backend（IOKit 通知）と hotplug.c を最初からビルドしており、
    足りなかったのは Go バインディング（`third_party/hanwen-usb`）の API だけだった。
    `Context.HasHotplug` / `Context.WatchHotplug` / `HotplugWatcher.Stop` を追加した。
  - 通知用の libusb コンテキストは `pkg/mtp.WatchUSB` がプロセスで 1 個だけ持ち続ける。
    接続処理（`Manager.Initialize` → `SelectDevice`）は従来どおり自前のコンテキストを使う
    （リーク修正済み。`mtp-libusb-context-leak.md` 参照）。
- 監視ロジック（`server/app_mtp.go` の `mtpHotplugMonitor`）:
  - 起動時に 1 回だけ接続を試す（`LIBUSB_HOTPLUG_ENUMERATE` は使わず、明示的に試す方が決定的でテストしやすい）。
  - ARRIVED は 500 ms の待機時間で束ねてから接続を試し、失敗したら 1 秒・2 秒後に再試行（計 3 回）して、次のイベントまで諦める。
    Android は「ファイル転送」を選ぶと接続し直すため、新しい ARRIVED で再開される。
  - LEFT は接続中なら `FetchStorages()` を 1 回だけ確認し、失敗したら切断扱いにする（どの端末が抜けたかは見ない）。
    未接続なら待機中・再試行中の接続試行を取り消す。
  - 定期ポーリングは一切しない。接続中に 5 秒ごと送っていた MTP 通信も無くなった。
  - libusb のコールバック内では同期 USB 通信が禁止されているため、コールバックはバッファ付きチャネルへの非ブロッキング送信だけを行う。
- ホットプラグが使えない、または開始に失敗した場合は、従来のポーリング（5〜60 秒の段階的延長＋接続中 5 秒確認）を
  そのまま使う。Windows は Windows 用 hotplug backend を外してビルドしているので常にこちらになる。

## Alternatives considered

- IOKit の通知を cgo で直接使う: macOS 専用になり、Linux 対応が別実装になるため不採用。
- ポーリングを残して間隔だけ短くする: 何もしていないときの負荷と検知遅延のトレードオフが残るため不採用。
- Windows のホットプラグ対応: Windows では Sony の Music Center for PC を使う運用のため保留（2026-09-26 ユーザー判断）。

## Constraints / Gotchas

- `HotplugWatcher.Stop` の順序は「停止フラグ → コールバック登録解除 → `libusb_interrupt_event_handler` →
  イベントループ終了待ち → `cgo.Handle` 削除」。コールバック内から Stop を呼ぶとデッドロックするので呼ばない。
- cgo の `//export` を持つファイルの前置き部には C の定義を書けないため、C の中継関数は `hotplug_callback.go`、
  Go 側のエクスポートは `hotplug_export.go` に分けてある。
- 実機での抜き差しはユニットテストで確認できない。偽のイベントを流すテストで状態遷移を確認し、実機はアプリで確認する。
