# Mobile 同期歌詞: 途中表示・ジャンプ時のスナップ

## Decision

- iPhone の歌詞画面（`NowPlayingSyncedLyricsScroll`）と iPad Sidecar（`SidecarSyncedLyricsList`）も Desktop と同じ不具合を抱えていた。
  - `activeIndex` が -1 で始まり、最初の tick で 40 などに飛ぶと、全行に 0.8s＋「行差×40ms」遅延付きの `.animation(value: y)` がかかり一斉に流れて見えた。
  - 行高は最初 44pt の仮値で並べ、測定結果が `onPreferenceChange` で届くと `y` が再度変わり、これもアニメーションしていた。
- `Core/LyricsStageKit.swift` に Desktop の `lyrics-motion.ts` 相当を追加。
  - `SidecarLyricsMotionPolicy.isJump(from:to:)`（閾値 `jumpThresholdLines = 2`、-1 → 途中行もジャンプ扱い）。
  - `SidecarLyricsActiveLineState`（`activeIndex` と `animatesMotion` を同じ `@State` 書き込みで更新する。`advance(to:immediate:)` が `resolveLyricsMotionTiming` に相当）。
- 各行の `.animation` は `value: y` ではなく `value: activeIndex` をキーにし、`animatesMotion` が false なら `nil`（スナップ）にした。
  行高の測り直しや回転・リサイズによる再配置は、行が変わらないのでアニメーションしない。
- 表示開始時は `onAppear` で現在位置から行を求め、`immediate: true` でスナップ。iPhone は `model.player.positionSeconds`、Sidecar は補間したリモート位置を使う。
- 行タップでのシーク（iPhone）とドラッグで覗く動作はそのまま。遠い行をタップしたときは次の tick でジャンプと判定され、スナップする。

## Alternatives considered

- `withTransaction` で `disablesAnimations` を立てる: 行ごとの `.animation` の側で判定したほうが、tick・`onAppear` 以外の経路（行高の測定など）も含めてひとつの状態で決まり、純粋関数のテストで挙動を固定できるため不採用。
- `.animation(value: y)` のまま行高の変化だけ抑える: 行高と行送りを区別する状態が別途必要になる。行の変化をキーにすれば、この区別は要らない。
- `init` で初期行を計算する: `model` が `@Environment` なので init では参照できず、`onAppear` で行う。

## Constraints / Gotchas

- tvOS の `UX-Music-TV/TVLyricsStageView.swift` も同じ `-1` 始まりで、`.animation(value: y)` を使っている。今回は対象外で未修正。同じ `SidecarLyricsActiveLineState` を使えば直せる。
- 検証は単体テストだけ。シミュレータには再生できるローカル曲も歌詞もなく（曲はデスクトップからの同期でしか入らない）、目視確認はしていない。
- 全体テストでは `LocalizationCatalogCompletenessTests` が 2 件落ちる。コミット済みの xcstrings に訳のないキーがあるためで、今回の変更とは関係ない。
