# バックグラウンド再生のメモリ削減 — ネイティブキュー化と WebView 駐機 計画

2026-08-20 ユーザー承認済み。

## 背景 / 問題

ウィンドウを閉じてもプロセスが生き続ける現設計（`HideWindowOnClose: true`、
`progress/background-window-close.md`）では、バックグラウンド再生中も WebView
（WebContent プロセス＋SPA の JS ヒープ・DOM・画像キャッシュ）が約 200MB を占有する。

調査の結果、ローカル再生（デコード・PortAudio 出力・EQ・FFT・デバイス選択・
OS Now Playing・ラウドネス適用）は **すでに Go 側で完結** しており、WebView に
残っている再生責務は次の 3 つだけと判明した:

1. **キュー・シャッフル・ループ・自動進行**（`src/renderer/js/features/playback-manager.ts`）
   — Go にキューの概念がなく、`next`/`prev` はリモコン（`/v1/remote/command`）からも
   OS メディアキー（`os-media-command`）からも一度レンダラーへ跳ね返している
2. **再生回数の計上判定** — `audio-playback-finished` を受けて JS が `SongFinished` を呼ぶ
   （JS 側の「選択中の曲」に対して計上しており、Go が実際に再生し終えた曲との照合がない）
3. **YouTube 公式 embed 再生** — iframe＋Core Audio プロセスタップ。公式再生の性質上
   WebView 必須（これは移管対象外）

## 確定方針

- **段階方式**: Phase 1（キュー Go 移管）→ Phase 2（WebView 駐機）→ **実測** →
  それでもメモリを食うなら Phase 3（Wails v2 フォークで WebView 破棄）。
  フォークは最初からはやらない。
- YouTube（embed）再生時はフロントエンドを生かしておく／駐機中に必要になったら復帰させる。

## Phase 1: ネイティブキュー（Go 移管）

- 純ロジックの再生キューを Go に新設（`pkg/playqueue`）: キュー内容・現在位置・
  シャッフル・ループ（off/all/one）・next/prev/jump。TDD で開発。
- `server/` に配線: `Player.SetOnFinished` からの **Go 内自動進行**（次曲のラウドネス
  ゲイン解決込み）、`next`/`prev` のリモートコマンド／OS メディアキーを Go 内で完結、
  キュー状態変化はイベントでフロントへ通知。
- 再生回数は「Go が実際に再生し終えた曲」に対して Go 側で計上（ローカル経路）。
  embed 経路の計上は従来どおり JS 起点を維持（二重計上を防ぐ）。
- キュー項目に YouTube 曲が含まれる場合: stream ルートは Go で解決して native 再生、
  embed ルートはレンダラーへイベント委譲（Phase 2 では駐機解除を挟む）。
- フロントの `playback-manager.ts` は「Go キューの表示・操作 UI」に薄くする。

## Phase 2: WebView 駐機/復帰

- ウィンドウ非表示（`visibilitychange`）かつ embed セッション非アクティブのとき、
  SPA を極小の駐機ページへ退避して JS ヒープ・DOM・画像キャッシュを解放。
- 再表示時に SPA を再ロードし、Go のキュー・再生状態から UI を復元。
- 駐機中に YouTube 再生要求（`remote-play-song` 等）が来たら SPA を復帰させてから実行。
- 畳む/開くの操作は 1 箇所のシームに集約し、Phase 3 の DestroyWebView に
  差し替え可能な形にする。
- 完了時に駐機前後のメモリ（本体 RSS / WebContent footprint）を実測して記録する。

## Phase 3（実測次第・任意）: Wails v2 フォーク

- `internal/frontend/desktop/darwin/WailsContext` に DestroyWebView / RecreateWebView を
  追加したフォークを `go.mod` の `replace` で適用。WebContent プロセス自体を消す。
- v2 はメンテナンスモードのため追従コストは低い。駐機方式の残量が許容範囲なら実施しない。

## 副産物 / 将来との整合

- キューと `next`/`prev` が Go に入ることで、`--serve` ヘッドレスでのローカル再生解禁
  （現状は設計上 GUI 専用、`markdown/appletv-servermode-plan.md`）への距離が縮む。
  実施するかは別判断だが、設計はそちらに背を向けない。

## 却下した代替案

- **フロントエンドの省メモリ化のみ**（非表示時のキャッシュ解放等）: rAF は非表示時に
  WebKit が自動スロットル済みで、200MB 級の削減は見込めないため主策にしない。
- **最初から Wails フォーク**: 駐機方式でも大半のメモリは返せる見込みで、フォークの
  取り分は「駐機後の残りベースライン」の差分のみ。実測してから判断する。
