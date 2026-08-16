# youtube_loudness_research ノート索引

新しいものが上。

- [embed-double-normalisation.md](embed-double-normalisation.md) — 公式再生（embed）がローカル曲より小さく鳴る件の調査。YouTube の埋め込みプレイヤー自身が `<video>.volume` を下げる形でラウドネス正規化の減衰を掛けていることをブラウザ実測で確認（`100%/60% DRC (cont.-14.6dB tgt.-19.0dB)` など）。アプリはその減衰前の `perceptualLoudnessDb` を基準に二度目の減衰を掛けており、embed 再生は YouTube の減衰量ぶん（実測 1〜4.4 dB）小さくなる。仮説は採択、`progress.md` の「減衰有無は未確定」を解消。修正案 A（`min(cont, −14)` で近似）／案 B（ホストページで実減衰を実測して返す、推奨）を提示。
