# Wails 再生：表示と実出力の不一致・途中停止（未解決）

**状態:** 一部解消（2026-05-15: 長時間一時停止後の再開不能を修正。表示と実出力の不一致全般は継続監視）
**環境:** `wails dev`、macOS、Go バックエンド（`pkg/audio` + PortAudio）

## 事象（ユーザー報告の要約）

- ナウプレ・キューなどの**表示は意図した曲に更新される**一方で、**スピーカーから流れている音が切り替わらない**、または**途中で再生が止まる**。
- 再生キューの行クリックや曲切り替え操作と関連して再現しやすいとのこと（完全な再現手順は未固定）。

## ターミナルで観測されたパターン

典型的なログのずれ（例）:

1. `[Audio] Playing: .../曲A.flac ...` — Go 側で最初の曲の再生開始は成功。
2. `[Wails] IncrementPlayCount called for: 曲B` — フロントから「曲 B で再生開始」とみなした処理（旧実装では `playbackStarted` が先行）が走る。
3. **`[Audio] Playing: ...曲B...` が続かない** — Go の `Player.Play` が成功パスまで到達していない、またはその前にフロント側処理が止まっている可能性。

過去の関連ログ（別セッション）では、急な `AudioStop` 連打などに伴い `close of closed channel` のあと **FLAC デコーダのパニック**（`slice bounds out of range`）も記録されている。スキップ連打まわりは `decoderLifecycleMu` などで緩和済みだが、**表示と音声の不一致**は別系統の可能性がある。

## すでに試した対策（いずれも「解決」とは確認できず）

| 対策 | 目的 |
|------|------|
| 再生キュー UI の `renderQueueView` を `playSong` 等と同期 | キューが空表示のままになる問題 |
| `initQueueSidebarMtpHandlers` を `ui.ts` の `initUI` から呼ぶ | キュー行クリックが無効だった問題 |
| `playSong` の Promise チェーンで直列化 | 重なった `play` で古い `AudioPlay` が後から勝つ競合の抑制 |
| `CSS.escape` を属性セレクタから排除（`cssQuotedAttrValue`） | UUID 先頭が数字のときの `.song-item` 検索失敗・警告 |
| キュー行 `draggable = false` | WKWebView でクリックがドラッグ扱いになり `play` に届かない疑い |
| `WailsApp.AudioPlay` 等の生成バインディング直接呼び出し | `getWailsApp()?.AudioPlay?.()` のサイレント失敗の排除 |
| Go: `decoderStop` 直列化（`decoderLifecycleMu`） | `close of closed channel` とそれに続くデコーダ破損 |
| **`playbackStarted` / IncrementPlayCount を `AudioPlay` 成功後に移動** | ログと実再生の順序の整合 |
| **`play()` が `boolean` を返し、失敗時は UI・インデックスを巻き戻し** | 表示だけ進む状態の防止 |
| Go: `AudioPlay` 失敗時に `[Audio] Play failed ...` をログ | 失敗理由の可視化 |

## 想定される残課題（仮説）

- **Wails IPC / 非同期:** `AudioStop` と `AudioPlay` の境界、または `play()` 内の `get-loudness-value` 等で例外・拒否が起き、**ブラウザコンソールには出るがターミナルには出ない**ケース。
- **Go 側 `Play` 失敗:** デバイス・ストリーム再オープン、パス正規化、FLAC デコーダ内部状態などで **エラー戻り**（`[Audio] Play failed` が出るはず）。
- **デコーダループ異常終了:** エラーパスでは `onFinished` が飛ばず、**無音で止まる**挙動の可能性（別途 `[Audio] Decoder error:` の有無を確認）。
- **Vite HMR / ページリロード:** 開発中の `page reload` が走るとフロント状態と Go 再生がずれる（再現条件の切り分け用）。

## 次の調査で有用な情報

1. 事象直後の**ターミナル全文**（`[Audio] Play failed`、panic、`Decoder error` の有無）。
2. **開発者ツールコンソール**の `[Player] play failed:` や Wails の process message error。
3. **操作手順**（キュークリックのみか、スキップ連打のあとか、特定フォーマットのみか等）。
4. 可能なら **Go の `Player.Play` 前後**に一時的なタイムスタンプログを増やし、JS の `AudioPlay` 呼び出し時刻と突き合わせる。

## 関連ファイル（参照用）

- フロント: `src/renderer/js/features/playback-manager.ts`、`src/renderer/js/features/player.ts`、`src/renderer/js/ui/ui-manager.ts`、`src/renderer/js/ui/element-factory.ts`
- Go: `server/app_audio.go`、`pkg/audio/player.go`
- 過去の再生バグ整理: `markdown/Issue-PlaybackBugs.md`（別件の修正履歴）

## 2026-05-15 追記: 長時間一時停止後に同じ曲を再開できない問題

- **事象**: 一時停止して数時間放置したあと、再生ボタンでは同じ曲を再開できない。他の曲をクリックすると再生できる。
- **原因**: Wails バックエンドの `Resume()` は `paused` フラグを戻すだけで、PortAudio の出力ストリームを再起動・再作成していなかった。長時間アイドルやスリープ復帰で OS 側のストリームが停止・無効化されると、UI は再開扱いでも実出力が復旧しない。
- **修正**: `pkg/audio/player.go` で `Resume()` 時にストリームの `Start()` を再実行し、30分以上の一時停止後はストリームを閉じて開き直す。短時間の再開では既に開始済みを表す `portaudio.StreamIsNotStopped` を正常扱いにする。
- **テスト**: `pkg/audio/player_resume_test.go` に、短時間再開で既存ストリームを開始するテストと、長時間一時停止後に古いストリームを閉じて新しいストリームを開始するテストを追加。

---

*この文書は「いったん記録用」に起こしたものです。解消したら本ファイルを更新するか、アーカイブ方針に合わせて移動してください。*
