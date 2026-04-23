# 既知の問題 (ISSUES.md)

このファイルには、現在確認されている問題点やバグ、未解決の課題を記録します。

## 進行中の問題

### [バグ] Desktop 再生周りのエッジケース（3件）

調査日: 2026-04-21  
対象: `Electron_Based_UX-Music/src/renderer/js/`

#### バグ1: mouseup がシークバー外で発火しない (`player-ui.js:97`)

- **現象**: シークバーをドラッグ中にカーソルを要素外でマウスを離すと、`isSeeking` フラグが `true` のままスタックする。シーク値が適用されず、再生も再開されない。
- **原因**: `mouseup` イベントが `progressBar` 要素のみに登録されており、要素外での解放を補足できない。
- **修正方針**: `document` レベルに `mouseup` リスナーを登録する。

#### バグ2: キャッシュグラフ再アクティブ時に EQ が適用されない (`audio-graph.js:201`)

- **現象**: サンプリングレートの異なる曲（例: 48kHz → 44.1kHz）に切り替えると、以前キャッシュされたグラフが再利用されるが、その際に EQ 設定が適用されない。
- **原因**: `applyEqualizerSettings()` は呼び出し時の `currentGraph` にのみ即時反映する設計で、`activateAudioGraph()` での再アクティブ化時に EQ の再適用が行われていない。
- **修正方針**: `activateAudioGraph()` 内でグラフを resume した後に EQ 設定を再適用する。

#### バグ3: `play()` 失敗時に skip 統計が送信されない (`player.js:236`)

- **現象**: `playLocal()` 内で `audioElement.play()` が AbortError 以外で失敗した場合、`onSongEnded()` を直接呼び出して次曲へ進む。この経路では `ipcRenderer.send('song-skipped', ...)` が呼ばれず、ラウドネス解析キューの統計がずれる。
- **原因**: エラー時のフォールバックパスが `handleSkip()` を通らない。
- **修正方針**: エラー時に `ipcRenderer.send('playback-error', song)` を送るか、`handleSkip` 相当の処理を追加する。


## 解決済みの問題

-   **[バグ] UX Music Mobile：アプリは一時停止なのに OS 側は再生中／リモート再生が無音**
    -   **原因**（3点が連鎖）:
        1. `advanceAfterEnd()` が単一曲キューで `guard queue.count > 1 else { return }` により即返却していたため、バックグラウンドでタイマーが止まると Now Playing が「再生中」で固着した。
        2. 曲が自然終了後（schedule 消費済）にリモート再生を押すと `resumeLocalPlaybackAfterPause()` が曲末尾にシークし、残フレーム 0 で無音になっていた。
        3. `remoteResumeAfterPlayCommand()` の `currentAudioFile == nil` パスが `.commandFailed` を返すため、非同期で始まる再生の状態が OS 側に伝わっていなかった。
    -   **修正**: `advanceAfterEnd()` で単一曲終了時も `syncIsPlayingFromNode` / `updateNowPlayingCentre` を呼ぶ。末尾 0.5 秒以内ならゼロから再生。非同期 `loadAndPlay` 開始時は `.success` を返す。
    -   **対応コミット**: `54734d7`

-   **[重大] De-node-integration 移行後の表示・再生不具合**
    -   **概要**: セキュリティ強化のための `contextIsolation: true` 移行後、レンダラープロセスで IPC 通信が正常に行われず、楽曲リストが空になる、再生が開始されないなどの問題が発生していた。
    -   **原因**: 
        1. `preload.js` の send ホワイトリストに不足チャネルあり
        2. **イベント名の不一致**: メインは `load-library` を送信、レンダラーは `library-loaded` を購読していた
        3. `normalize-view.js` でコールバック引数に不要な `event` を含んでいた
    -   **修正**: ホワイトリストへのチャネル追加、イベント名統一、引数形式の修正を実施。

-   **[バグ] クイズ終了時にスコアが保存できない**
    -   **原因**: ランキングデータファイル(`quiz-scores.json`)が空の場合、データを配列として正しく初期化できず、`scores.push`が失敗していた。
    -   **修正**: `data-store.js`を修正し、対象ファイルが空の場合は常に適切な型（この場合は空の配列`[]`）で初期化するようにした。

-   **[バグ] 起動時にプレイリストが表示されない**
    -   **原因**: 楽曲ライブラリの読み込み完了を待たずにプレイリスト情報を要求していたため、空のリストが描画されていた。
    -   **修正**: IPC通信の順序を見直し、ライブラリの読み込みが完了した後にプレイリストを要求するように変更した。

-   **[UI] Light Flightモードでのレイアウト崩れ**
    -   **問題**: Light Flightモードを有効にすると、アルバムアートワークだけが消失する。右側のプレビューのアートワークも消失する。線は正しく表示される。
    -   **解決策**: **アルバムアートのグループ表示**を関数のように扱えるように改善し、それをLFモード時に使用することによって安定的にUIを構築する。
