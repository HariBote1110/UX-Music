# Apple TV フルスクリーンNow Playing・同期歌詞・アンビエントモード（Phase 2）

## Decision

- **歌詞ロジックの共有方式**: `LRCParser.swift`（`UX-Music-Mobile/Core/LRCParser.swift`）は
  Foundationのみに依存する純粋enumのため、iOS側のファイル参照をそのままTVターゲットの
  Sourcesビルドフェーズに追加する形で共有した（ファイル複製なし）。`activeLineIndex(in:at:)`が
  現在行判定の唯一の実装になり、TV側は`RemoteLyricsPayload`（`RemoteAPIClient`、既にTV
  ターゲットで共有済み）から取得した`.lrc`本文をそのまま渡すだけ。iOS側の
  `NowPlayingLyricsScreen`が持つ和訳（bilingual）マージ・カスケードアニメーション・
  手動スクロール検出などのUI層ロジックは移植していない（10フィート表示は行間隔を大きく
  取ったシンプルな縦スクロール＋ハイライトで十分と判断、`TVSyncedLyricsView`）。
- **メディアコントロールの共有方式**: `MusicPlayerService`は既にPhase 1-1の時点でTVターゲットに
  ファイル参照共有済みで、`MPRemoteCommandCenter`/`MPNowPlayingInfoCenter`の配線
  （`installRemoteCommandHandlers`/`updateNowPlayingCentre`）もUIKit/MediaPlayerベースのまま
  tvOSでビルド・動作することが Phase 1-1 のスパイクテストで既に確認済みだったため、
  **TV専用の実装やシームは追加しなかった**。`TVNowPlayingView`のトランスポートボタンは
  `player.togglePlayPause()`/`player.next()`/`player.previous()`を直接呼ぶだけで、Siri Remote
  物理ボタン・Control Centre経由の操作は既存の`MPRemoteCommandCenter`ハンドラがそのまま
  受ける（両経路が同じ`MusicPlayerService`インスタンスを操作するため状態は自動的に一致する）。
- **画面遷移**: `TVBrowseView`にアルバム再生開始時の自動遷移（`fullScreenCover`）と、
  再生中のみ表示される「再生中の項目」フォーカス可能バー（`TVNowPlayingAffordance`）の
  2つの入口を実装。Menu/戻るはtvOSの標準動作（`fullScreenCover`はSiri RemoteのMenuで
  自動的にdismissされる）に任せており、独自ハンドラは書いていない。dismiss後も
  `MusicPlayerService`のAVAudioEngineはView階層と独立して動き続けるため再生は継続する。
- **アンビエント状態遷移**: `TVAmbientStateMachine`（純粋enum、`next(current:isPlaying:
  secondsSinceLastInteraction:)`）としてTDDで実装。しきい値は`idleTimeout = 30`秒（定数）。
  再生停止中は`secondsSinceLastInteraction`の値に関わらず必ず`.normal`に戻る（無音のまま
  アンビエント演出が居座らないように）。ビューは`TimelineView(.periodic(from:by: 1))`で
  1秒ごとにこの純粋関数を再評価し、`onMoveCommand`/`onTapGesture`/`onExitCommand`のいずれかで
  `lastInteractionAt`をリセットする。
- **画面スリープ**: tvOSは音声再生中でも既定でスクリーンセーバー/スリープに入るため
  （オーディオ専用アプリだからといって自動的に画面が点いたままにはならない）、
  `UIApplication.shared.isIdleTimerDisabled`を`player.isPlaying`と同期させる形にした
  （再生中のみtrue、一時停止・画面離脱で必ずfalseに戻す）。常時trueにしないのは計画書の
  「tvOSのスリープ設定を妨げない」制約に対応するため。

## Alternatives considered

- **iOSの`NowPlayingLyricsScreen`ビューそのものをTVターゲットに共有**: 見送り。カスケード
  アニメーション・ドラッグジェスチャ・和訳マージなど電話サイズ前提のインタラクションが
  10フィート表示と噛み合わず、`GeometryReader`ベースの複雑なオフセット計算をTVの
  フォーカスエンジンと共存させる価値が低いと判断。純粋なタイミングロジック
  （`LRCParser`）のみ共有し、表示は`TVSyncedLyricsView`として作り直した。
- **`MusicPlayerService`にtvOS用の`#if os(tvOS)`分岐を追加**: 不要と判断。既存コードが
  変更なしでビルド・動作することをテストで確認できたため、分岐を増やして複雑化させる
  理由がなかった。
- **アンビエント遷移をタイマー駆動のクラスにする**: 見送り。`TimelineView`+純粋関数の方が
  XCTestで時間経過をシミュレートしやすく、Viewのライフサイクルにも依存しない。

## Constraints / Gotchas

- **`MusicPlayerService`は`@Observable`（Observationフレームワーク）であり
  `ObservableObject`ではない**。当初`@ObservedObject var player: MusicPlayerService`で書いて
  ビルドエラーになった（`ObservedObject`は`ObservableObject`準拠を要求する）。TV側のView群は
  `let player: MusicPlayerService`（プレーンな参照渡し、Observation自動追跡）に統一した。
  `TVConnectedView`側も同様に`@StateObject`ではなく`let`で保持する。
- **プレイリストからの再生は未実装**: `TVPlaylistCard`はまだタップ操作を持たない
  （`progress/tvos-playback.md`の時点でも同様）。Now Playing自動遷移はアルバム再生開始
  経路のみで検証済み。プレイリスト再生が実装されたタイミングで同じ
  `nowPlayingPresented = true`を追加すればよい。
- **歌詞なし曲の判定**: `RemoteLyricsPayload.found == true`かつ`type == "lrc"`のときのみ
  同期歌詞レイアウトに切り替える。プレーンテキスト歌詞（`type == "txt"`）はタイムスタンプが
  なく現在行ハイライトができないため、10フィート表示ではアートワーク中心レイアウトに
  フォールバックする（iOS版のような静的テキスト表示は今回実装していない）。
