# 公式再生（embed）の二重ラウドネス正規化

## 目的 / 仮説

「YouTube 公式再生（embed + プロセスタップ）とローカル音源で明らかな音量差がある」というユーザー報告の真偽を確かめる。

仮説: YouTube の埋め込み／ウォッチページのプレイヤー自身がラウドネス正規化（減衰）を掛けており、
UX-Music 側はその減衰前のコンテンツラウドネス（`perceptualLoudnessDb`）を基準にもう一度ゲインを
掛けている。結果として embed 曲だけが二重に減衰し、ローカル曲より小さく鳴る。

反証条件: プレイヤーが減衰していない（`video.volume === 1` かつ stats に減衰表示なし）なら仮説は棄却。

`progress.md`（2026-07-13 の節）に「埋め込みプレイヤー自身の減衰有無は未確定」と明記されており、
未検証のまま「ソース音源のラウドネス」として扱う設計になっていた。本ノートはその未検証事項の決着。

## 環境

- ホスト: macOS 26.5.2 (Darwin 25.5.0), Apple Silicon Mac
- 対象コード: UX-Music `main` @ 7b1c723
- 計測: Claude Code 内蔵ブラウザ（Chromium 系）で youtube.com のウォッチページを開き、
  `movie_player.getStatsForNerds()` と `<video>.volume` を JavaScript から読む
- 参照した実装:
  - `src/renderer/js/features/playback-gain.ts` … `resolveEmbedPlaybackGain` / `resolveLocalPlaybackGain`
  - `src/renderer/js/features/player.ts` … `applyEmbedNormalisationGain`
  - `internal/youtube/loudness.go` … `EffectiveLoudnessLUFS`（`perceptualLoudnessDb` 優先、無ければ `-14 + loudnessDb`）
  - `pkg/audio/player.go` … `SetNormalisationGain`（embed / ローカル共通の baseGain）

## 手順

1. `https://www.youtube.com/watch?v=<id>` を開く（embed URL は wails:// 由来ではない環境でも
   Referer 不足でエラー 153 になったため、同一プレイヤーコアのウォッチページで代替した）。
2. `<video>.muted = true` にしてから `movie_player.playVideo()` で再生開始。
3. 5 秒後に `movie_player.getStatsForNerds().volume` と `<video>.volume`、`movie_player.getVolume()` を取得。
4. `loadVideoById` で動画を切り替えて 2〜3 を繰り返す。

## 結果

| videoId | stats の volume 表示 | `video.volume` | 実減衰 | API 上の音量 |
|---|---|---|---|---|
| 9bZkp7q19f0 (Gangnam Style) | `100%/60% DRC (cont.-14.6dB tgt.-19.0dB)` | 0.5998 | −4.44 dB | 100 |
| dQw4w9WgXcQ | `100%/89% (cont.-13.0dB tgt.-14.0dB)` | 0.8933 | −0.98 dB | 100 |
| 1La4QzGeaaQ | `100%/100% DRC (cont.-17.6dB tgt.-14.0dB)` | 1.000 | 0 dB | 100 |
| 5qap5aO4i9A | `100%/100%`（ラウドネス情報なし） | 1.000 | 0 dB | 100 |

読み取れること:

- プレイヤーは `getVolume() === 100` のまま、**`<video>.volume` を下げる形で自前の正規化減衰を掛けている**。
  減衰量 = `max(0, cont − tgt)`（実測: 4.44 dB ≒ −14.6 −(−19.0)、0.98 dB ≒ −13.0 −(−14.0)）。
- stats の `cont.` は `internal/youtube/loudness.go` が使う `perceptualLoudnessDb` と一致する
  （dQw4w9WgXcQ: 実測 −13.0 dB、コード内の実測値 −13.01）。**アプリが基準にしている値そのものが、
  YouTube 自身が減衰に使っている値**である。
- ターゲットより静かなコンテンツ（1La4QzGeaaQ, cont −17.6 < tgt −14.0）は **ブーストされない**。
  減衰は片方向のみ。
- ターゲットは常に −14 dB とは限らない（Gangnam Style では DRC 付きで −19.0 dB）。

これを UX-Music の経路に当てはめると（`targetLoudness` 既定 −18.0 LUFS）:

| 経路 | 実際にタップへ届くラウドネス | アプリが掛けるゲイン | 最終出力 |
|---|---|---|---|
| ローカル曲（実測 −11.1 LUFS = ライブラリ中央値） | −11.1 | −6.9 dB | **−18.0 LUFS** |
| embed / dQw4w9WgXcQ | −13.0 −0.98 = −14.0 | −18 −(−13.0) = −5.0 dB | −19.0 LUFS（1.0 dB 小さい） |
| embed / 9bZkp7q19f0 | −14.6 −4.44 = −19.0 | −18 −(−7.31〜−14.6) ≒ −10.7〜−3.4 dB | 最大 −4.4 dB 小さい |

すなわち **誤差 = YouTube 自身の減衰量 = max(0, cont − tgt)**。
現代の音楽 MV は cont が −14 より大きい（うるさい）ものが大半なので、
embed 再生は常に 1〜7 dB ほど小さく鳴る。静かな動画では誤差 0。

ライブラリのラウドネス分布（`~/Library/Application Support/UX-Music/loudness.json`、実測値 769 件）:
中央値 −11.1 LUFS / 最小 −23.7 / 最大 −6.3。ローカル側は正しく −18 に揃うため、差は体感できる。

## 結論

**仮説は採択。ユーザーの気のせいではない。** 埋め込みプレイヤーは自前でラウドネス正規化の減衰を掛けており、
UX-Music はその減衰前の値（`perceptualLoudnessDb`）を「タップに届く音のラウドネス」とみなして
二度目の減衰を掛けている。embed 再生はローカル曲より **最大で「YouTube の減衰量」ぶん（実測 1〜4.4 dB、
一般に 0〜7 dB 程度）小さく鳴る**。`progress.md` の「減衰有無は未確定」は解消（減衰あり）。

ゲイン計算・適用経路（`pkg/audio/player.go` の baseGain）は embed とローカルで共通であり、そこに
非対称性はない。原因は入力となるラウドネス値の意味の取り違えのみ。

## 次の一手 / 未検証事項

修正案は 2 つ。案 B を推奨。

- **案 A（近似・低コスト）**: `resolveEmbedPlaybackGain` を
  `gainDb = target − min(effectiveLoudness, ytTarget)`（`ytTarget = −14`）に変更する。
  静かな動画は従来どおり、うるさい動画は −14 として扱われるので二重減衰が消える。
  ただし Gangnam Style で観測された `tgt −19.0`（DRC 適用時）には追随できず、その場合 5 dB 残る。
- **案 B（実測・堅牢）**: ループバックの embed ホストページ側で、再生開始後に
  `movie_player.getStatsForNerds().volume`（または `<video>.volume`）を読み、実際の減衰量を
  postMessage で本体へ返す。ゲインは `target − (cont + 20log10(video.volume))` で算出する。
  YouTube 側のターゲット変更や DRC 有無に自動追随する。

未検証:
- DRC（`tgt −19.0`）がどの条件で選ばれるか（動画側／アカウント設定／クライアント種別）。
- `<video>.volume` が再生途中で変化するか（曲の途中でターゲットが変わるか）。実装時は
  一定間隔での再読み取り、または `volumechange` 監視が要るかもしれない。
- ホストページのプレイヤーは `mute()` 経由で開始するが、`muted` と `volume` は独立なので
  減衰量の読み取りは阻害されないはず（未実測）。
