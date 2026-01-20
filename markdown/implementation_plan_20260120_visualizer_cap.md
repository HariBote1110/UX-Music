# 実装プラン: ビジュアライザーのバー伸長抑制

## 1. 現状分析
- `src/renderer/js/visualizer.js` 内の `draw` 関数でバーの高さを計算している。
- 計算式: `const targetHeight = (scaledValue * multiplier * 20) + 4;`
- ここで `scaledValue` は 0~1、`multiplier` は最大 1.3 程度。
- その後 `Math.min(20, Math.max(4, newHeight))` で 4px〜20px に制限されている。
- 結果として、`targetHeight` が 20 を超えやすく、バーが上限に張り付いて見える。

## 2. 修正内容
- バーの最大高さを制限するのではなく、スケーリングの係数を調整して、視覚的に「伸び切る」手前で動くようにする。
- 係数を `20` から `12`〜`14` 程度に変更することを検討。
- もしくは、コンテナの高さ（20px）に対して、少し余裕を残した値を最大値とする。

### 具体的な変更内容
- `src/renderer/js/visualizer.js`:
  - `targetHeight` の計算で使用している係数 `20` を `14` に変更。
  - `targetHeight = (scaledValue * multiplier * 14) + 4;` とすることで、最大値が `(1 * 1.3 * 14) + 4 = 22.2` となるが、スムージングや平均化により 20px に到達する頻度が激減する。
  - `Math.min(20, ...)` のキャップは維持し、はみ出しを防ぐ。

## 3. 手順
1. `git status` で変更がないか確認。
2. `package.json` のバージョンを更新 (`0.1.9-Beta-5j`)。
3. `src/renderer/js/visualizer.js` を修正。
4. 動作確認（ユーザーによる確認）。
5. `progress.md` に追記。
