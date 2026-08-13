# Apple TV Now Playing — ストリーム再生中にテキスト列が消える不具合

## 根本原因（状態の組み合わせ）

実機の外部再生（ストリームファースト）フローでは、`TVNowPlayingView.loadLyrics()` が曲切り替え時に
**歌詞取得の`await`が完了するまで`lyricsLines`をクリアしていなかった**。一方
`MusicPlayerService.beginExternalPlayback` は`currentSong`/`positionSeconds`を**同期的に即座に**
新曲へ切り替える。結果として、フェッチ中の一瞬（実機のLAN越し取得は`songstream`ハーネスの
到達不能ホストと違い実際に数百ms〜数秒かかる）、

- `currentSong` は新曲（B）
- `lyricsLines` は前曲（A）の歌詞行のまま
- `positionSeconds` は`0`（新曲用にリセット済み）

という不整合な組み合わせで `TVNowPlayingLyricsLayout` がレンダリングされていた。この時
`HStack(alignment: .center, …)` が、可変高さのテキスト列（歌詞ブロックの有無で高さが変わる）を
固定高さ420ptのアートワークカードに対して**毎フレーム中央寄せし直す**ため、テキスト列の高さが
変化するたびに視覚的に上下へジャンプする——これが「テキスト部分が全部上に消滅してる」という
実機報告の正体。`UXTV_PREVIEW=songstream`ハーネスでは歌詞エンドポイントが接続不可ホストへ
即座に失敗していたため、この不整合ウィンドウが再現せず「ハーネスでは問題なし」に見えていた。

再現には、ハーネスのモック`URLProtocol`に`/v1/remote/lyrics`応答を追加（`none|empty|lrc`の3値、
`UXTV_SONGSTREAM_LYRICS`環境変数で切替）して実フローに近づける必要があった
（`UXMusicTVApp.swift`の`UXTVSongStreamMockURLProtocol`）。

## 修正

1. `TVNowPlayingView.loadLyrics()`: `await`前に`lyricsLines = []`を同期的に実行し、フェッチ中は
   常に「歌詞なし」状態（アートワーク中心レイアウト）にフォールバックさせ、前曲の歌詞と新曲の
   position/artworkが混在しないようにした。
2. `TVNowPlayingLyricsLayout`: `HStack(alignment: .center, …)` → `.top`に変更。アートワークカードと
   テキスト列の両方を上端揃えにすることで、テキスト列の高さが変わってもタイトル/アーティストの
   縦位置が動かなくなる（歌詞ブロックの有無に依存しない安定した位置）。末尾の実質無効だった
   `Spacer(minLength: 0)` は削除。

## 検証

`UXTV_PREVIEW=songstream` + `UXTV_SONGSTREAM_LYRICS={none,empty,lrc}` の3バリアントをスクリーン
ショットで確認（`/tmp/claude-501/npfix_pre_{none,empty,lrc}.png` および経過フレーム）。いずれも
タイトル/アーティスト/歌詞ブロックが同じ縦位置に固定されることを確認。

## Alternatives considered

- HStack全体を`GeometryReader`で固定高にラップする案 → 冗長で、`.top`揃えだけで十分に位置が
  安定するため採用しなかった。
- `lyricsLines`をクリアせず「フェッチ完了まで前の歌詞を出し続ける」案 → 曲またぎで前曲の歌詞が
  一瞬表示される方が誤解を招くため却下（歌詞なし状態へフォールバックする方が既存のPhase 2仕様
  「歌詞なし曲はアートワーク中心レイアウト」と整合する）。

---

# ストリーム再生中の2件の実機不具合（engineQueue↔MainActorデッドロック / resume時の曲混線）

## 根本原因1: UIハング

`TVRelayStreamPlayer.start()`/`stop()`は`engineQueue.sync`で実装されており、常にMainActor
（`TVSongStreamController`/`TVRelayPlaybackController`はどちらも`@MainActor`）から同期的に
呼ばれていた。`engineQueue`自体はURLSessionのデリゲートコールバック内で`DispatchQueue.main.async`
（非同期）しか行っておらずコード上は真のデッドロック経路が見当たらなかったが、実機の
AVAudioEngine内部（レンダースレッドとのロック）はシミュレータ/ユニットテストでは再現しない
経路でMainActorを間接的にブロックしうる、かつ`.sync`である以上MainActorは`engineQueue`が
空くまで無条件に待たされる——曲切り替え連打時にこの待ち時間が体感できるレベルの「ハング」と
して報告された可能性が高い。

## 修正1

`start()`/`stop()`を`engineQueue.sync` → `engineQueue.async`に変更し、MainActorを一切ブロック
しないようにした。整合性は以下で維持：

- `generation`カウンタを`engineQueue`ではなく`NSLock`で保護される独立プロパティに変更
  (`generationLock`/`bumpGeneration()`)。`start()`/`stop()`は**同期的に**`generation`をbumpして
  から実際のエンジン操作を`engineQueue.async`へ委譲するため、呼び出し側が`engineQueue`を待たずに
  古い世代のフレームを即座に無効化できる。
- `stop()`の`engineQueue.async`クロージャは**`[weak self]`ではなく`[self]`（強参照）**でキャプチャ。
  呼び出し元（`TVSongStreamController.teardown()`）は`stop()`から戻った直後に自身の参照を破棄する
  ため、弱参照のままだと非同期クロージャが実行される前にオブジェクトが解放され、
  `engine.detach`/`.stop()`が一度も走らずクラッシュ修正（`generation`ガード）が守っていたはずの
  不変条件が別の形で崩れる。強参照でオブジェクトを一時的に生き延びさせ、キューの仕事完了後に
  自然に解放させる。
- 同一プレイヤーインスタンス内で`engineQueue`はシリアルのままなので、`stop()`→`start()`の
  投入順序（FIFO）はキュー内で保証される。曲切り替えは`TVSongStreamController`が毎回**新しい**
  `TVRelayStreamPlayer`インスタンスを生成するため、そもそも複数曲間で同じ`engineQueue`を
  共有せず、インスタンス跨ぎの順序問題は発生しない。

`elapsedSeconds`/`pause()`/`resume()`は引き続き`engineQueue.sync`のまま——MainActorへ折り返す
処理を一切含まないため真のデッドロックリスクがなく、即値が必要（進捗ミラー/トグル操作）な
ため非同期化しなかった。

## 根本原因2: resumeで最初の曲が復活する

コード読解では単一の`TVPlaybackController`インスタンス内で
`player.externalPlaybackCommandHandler`は初期化時に一度だけ設定され、常に`self.streamController`
（`TVSongStreamController`の単一インスタンス）へ委譲する設計になっており、`TVSongStreamController`
自身も`streamPlayer`を毎回`start()`で差し替えるため、pause/resumeは常に「現在の」ストリームへ
ルーティングされるはずだった——実機報告を静的読解だけで確定的に再現することはできなかった
（要実機/実ネットワークでの追加調査）。ただし、この経路が壊れていないことをリグレッション
テストとして固定化した（下記）。

## テスト

- `TVPlaybackControllerStreamSwitchTests.testSwitchingToADifferentSongMidStreamDoesNotHang`:
  A再生開始直後（レンダリング開始を待たず）にBへ切り替えても`await`が完了することを確認
  （ハングすればXCTestのタイムアウトで検出される）。
- `TVPlaybackControllerStreamSwitchTests.testPauseThenResumeAfterSwitchingStreamsAffectsCurrentSongOnly`:
  A→B切り替え後のpause/resumeが、A用の`TVRelayStreamPlayer`（`TaggedTVRelayStreamPlayer`で
  `pause()`/`resume()`呼び出し回数を計測）には一切届かず、B用にのみ届くことを確認。
  このテストのために`TVRelayStreamPlayer`から`final`を外した（他に差し替え可能なテストシームが
  存在しなかったため）。
