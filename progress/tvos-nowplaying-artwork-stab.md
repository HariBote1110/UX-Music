# TV NowPlaying: 歌詞ロード時のジャケット突き刺さり（レイアウト崩壊）

## 決定
- 歌詞なし用 `TVNowPlayingArtworkLayout`（中央寄せVStack・560pt）と歌詞あり用 `TVNowPlayingLyricsLayout`（左上寄せHStack・420pt）の2ビュー木を `lyricsLines.isEmpty` でスワップする構造を廃止し、常時マウントされる単一の `TVNowPlayingStageLayout` に統合した。
- 歌詞は非同期ロード（`.task(id: currentSong?.id)`）のため、スワップは再生中に無遷移で発生していた。ZStackレベルの `.animation(value: ambient)` がそのスワップのトランザクションを捕捉すると、アートワークが「中央560pt→左上420pt」へ補間移動し、ジャケットが画面に突き刺さるように見えた。
- 統合後、歌詞の有無が変えるのは (a) アートワークサイズ（560⇔420、このビューにスコープした `.animation(value: hasLyrics)` で明示的にアニメーション）と (b) テキスト列下段の子（歌詞ステージ⇔トランスポートバー、`.transition(.opacity)`）のみ。コンテナのアイデンティティ切替が構造上存在しないため、意図しない補間は発生し得ない。

## 併せて直した含意バグ
- 高さ予算: `contentHeight` が下部 `safeAreaInset`（プログレスバー）の消費分を無視していたため、`progressBarReservedHeight` を控除。
- 封じ込め: `TVLyricsStageView` に `.clipped()` を追加（エッジフェードのmaskの偶発的クリップに依存しない）。
- 状態衛生: `TVLyricsStageView.lineHeights`（@Stateの行高キャッシュ）を `lines` 変更時にリセット。旧曲の行高が新曲の累積オフセット計算に混入する1フレーム以上のズレを排除。

## 却下した代替案
- 最初の修正（コミット2f0a339）: 歌詞カラムに有限の高さ上限を与えるだけの対処 → `GeometryReader` の貪欲な膨張は抑えたが、真因（ビュー木スワップのアニメーション捕捉）には無効で、ユーザー環境で崩壊が再現した。
- 2ビュー木を残して `.transition(.opacity)` を付ける案 → 遷移忘れ・トランザクション捕捉の再発余地が残るため、構造統合を選択。

## 制約・注意点
- 歌詞なし曲の画面も左上寄せのサイドカー型配置に統一された（従来は中央寄せ）。意図的なデザイン変更。
- この環境はCoreSimulatorが壊れておりtvOS実機/シム確認は不可。SDKビルドは成功。
