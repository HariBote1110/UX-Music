# Desktop 同期歌詞: 途中表示のスナップと行クリックシーク

## Decision

- 曲の途中で歌詞（サイドバー／フルスクリーン）を開くと全行が一斉に流れる不具合の原因は2つ。
  - サイドバー: `updateSyncedLyrics` は `#lyrics-container` が非表示の間は早期 return するため、
    表示中の行番号が -1（または古い値）のまま残る。表示直後の tick で -1 → 40 のように飛び、
    全行に 800ms の overshoot 遷移＋「行差×40ms」の遅延（数秒）が付いて回って見えた。
  - フルスクリーン: 開いた時点では `applyLyricsMotion(-1, true)` で先頭に並べ、次の tick で現在行へ同じくアニメーションしていた。
- 行送りの遷移判定を `src/renderer/js/features/lyrics-motion.ts` の純粋関数 `resolveLyricsMotionTiming` に切り出し、両ビューで共有。
  - 行差が 2 行以下は従来のカスケード（800ms・40ms/行）。3 行以上（シーク・途中表示）と immediate は遷移なしでスナップ。
  - 2 行までを通常扱いにしたのは、ポーリング間隔（200〜500ms）内に短い行を1つ飛ばしただけの通常再生を崩さないため。
- 表示開始時は再生位置（`player.ts` の `getCurrentTime()`）から行を求め直してスナップする。
  - サイドバーは `#lyrics-container` が active になった次フレームで、非表示中に測った行高キャッシュ（0 → 1px 扱い）も捨てて測り直す。
  - フルスクリーンは `syncLyrics()` の初期配置で現在行を使い、ResizeObserver 発火時にも現在行で遷移なし再配置する。
- LRC 行クリックで `state.currentLyrics[i].time` へ `seek()`。Mobile の `nowPlayingLyricsSeekTime` と同じくオフセットなし。
  クリック後は同じ判定で表示もその行へ移す（遠い行ならスナップ）。txt 歌詞はクリック不可のまま。

## Alternatives considered

- ジャンプ時に短い一括遷移（例: 250ms・遅延なし）: 途中表示と区別する文脈が増えるわりに効果が小さいため、スナップに統一。
- 非表示中も `updateSyncedLyrics` で行番号だけ追う: 表示直後の最初の tick まで古い位置が見えるうえ、一時停止中は tick が来ないため不採用。
- シークを CustomEvent で仲介: `lyrics-manager` → `lrc-editor` → `player` の循環が既に存在し、実行時参照のみなので直接 import で問題ない。

## Constraints / Gotchas

- `lyrics-manager.ts` と `player.ts` は相互 import。`player.js` の関数はモジュール評価時に呼ばないこと。
- 行クリックはテキスト選択中（ドラッグ選択）なら無視する。右クリックのコンテキストメニューは従来どおり。
- ホバー表現は色だけ変える（opacity/transform の遷移時間はモーション用変数に連動しているため触らない）。
- 見た目は Wails バックエンドなしでは歌詞を読み込めず、ブラウザプレビューで確認できない。jsdom テストで挙動を確認済み、実機での目視は未実施。
