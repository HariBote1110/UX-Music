# 既知の問題 (ISSUES.md)

このファイルには、現在確認されている問題点やバグ、未解決の課題を記録します。

## 進行中の問題

-   **[バグ] UX Music Mobile：アプリは一時停止なのに OS 側は再生中／リモート再生が無音**
    -   **概要**: アプリ UI では一時停止しているのに、ロック画面・コントロールセンター・Dynamic Island など OS の Now Playing は「再生中」のままになる。OS 側の再生ボタンを押しても「再生中」表示のまま変わらず、**音は鳴らない**（実再生と OS 表示が両方ずれる）。
    -   **想定環境**: `UX-Music-Mobile`（SwiftUI）、ローカル `AVAudioEngine` + `AVAudioPlayerNode`、`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` でロック画面連携。
    -   **試したが解消しなかった対策**（参考・履歴）:
        1. `MPNowPlayingInfoCenter.playbackState` と `MPNowPlayingInfoPropertyPlaybackRate` を `isPlaying` と揃える、`updateNowPlayingCentre()` 先頭で `syncIsPlayingFromNode()`。
        2. リモートの `play` / `pause` / `toggle` を `DispatchQueue.main.sync` 経由で同期し、`.success` を返す前に Now Playing を更新。
        3. 一時停止からの再開で `play()` が効かない場合に `seek` でバッファを張り直してから再生（`resumeAfterSeek`）。
        4. `UIApplication.shared.beginReceivingRemoteControlEvents()` を起動時に呼び出し。
    -   **未調査・次に疑うとよい点**:
        -   別プロセス／別セッション（CarPlay、他アプリ、Siri）との Now Playing の取り合い。
        -   iOS バージョン固有の `MPNowPlayingInfoCenter` と `AVAudioSession` の組み合わせ（バックグラウンド時のタイマー `tickPlaybackPosition` の頻度・停止）。
        -   `AVAudioPlayerNode` の `isPlaying` と実際のオーディオ出力・スケジュール残量の不一致（曲終端後の単一曲キューなど）。
        -   実機ログ（`MPRemoteCommand` のスレッド、`nowPlayingInfo` 更新の直前直後）での再現手順の固定化。
    -   **関連コード（目安）**: `UX-Music-Mobile/UX-Music-Mobile/Services/MusicPlayerService.swift`（Now Playing 更新、リモートコマンド）、`UXMusicMobileApp.swift`（`beginReceivingRemoteControlEvents`）。


## 解決済みの問題

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
