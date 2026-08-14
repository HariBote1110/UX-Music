# サイドカー画面のUI改善（アートワーク正方形化・シークバー配置・歌詞モーション・背景グラデーション）

## Decision

ユーザー報告の3点＋追加スコープ1点をすべて `SidecarScreen.swift` とその周辺の純関数（`SidecarDirective.swift`）で解決した。

1. **アートワークの黒帯**: 原因は `artworkAndInfo` が `.aspectRatio(1, contentMode: .fit)` を「列の実測サイズが正方形に近い」という前提で使っていたこと。実際には列の提案サイズ（HStack行の高さ）は幅と一致しないため、`.fit` が正方形でない箱にフィットして左右（または上下）に余白＝黒帯が生じていた。`SidecarArtworkLayout.squareSide(columnWidth:columnHeight:margin:maxSide:)` という純関数で列の実測値から明示的な正方形辺長を計算し、`GeometryReader` 越しに `.frame(width:height:)` で直接サイズを固定する方式に変更。`ArtworkImageView` 内の `Image` は元々 `.aspectRatio(contentMode: .fill)` なので、正方形フレームさえ与えれば非正方形画像でも黒帯なくフィル＋クリップされる。

2. **シークバーの位置**: 元々の実装ではプログレスバーは別レイヤーの `VStack { Spacer(); progressBar }` で画面下部に固定していたが、`artworkAndInfo` が `.aspectRatio(1, .fit)` の副作用で縦に大きくなりすぎ、画面中央寄せのテキストブロックの下端がバーの位置と視覚的に衝突していた（「アーティスト名とアルバム名の間にシークバーがある」ように見えた根本原因）。今回の正方形化で高さが縮み衝突は解消。加えてバー自体も要件どおり「経過/残り時間ラベルをバー端にインライン配置」する `HStack` へ再設計（以前は時間ラベルがバーの下に別行で並んでいた）。バー本体は常に表示、時間ラベルのみ既存の chrome フェード対象のまま。

3. **歌詞モーション**: Desktop版フルスクリーンプレイヤー（`src/renderer/js/features/fullscreen-view.ts` の `applyLyricsMotion`、`src/renderer/styles/components.css:2137-2162`）の仕様を移植:
   - `ANCHOR_RATIO = 0.35` → `SidecarLyricsMotionPolicy.scrollAnchor = UnitPoint(x: 0.5, y: 0.35)`（アクティブ行は画面中央でなく35%の位置に固定）
   - `MOTION_DURATION_MS = 800` → `SidecarLyricsMotionPolicy.duration = 0.8`
   - `MOTION_DELAY_STEP_MS = 40` → `SidecarLyricsMotionPolicy.staggerDelay(forDistance:)`（アクティブ行からの距離に応じて遷移開始を段階的に遅延させ、さざ波のような動きにする）
   - `.fs-lyrics-inner.fs-lrc p.active { transform: scale(1.091) }` → `SidecarLyricsMotionPolicy.activeLineScale = 1.091`（フォントサイズ切替でなく `scaleEffect` で強調。Desktop同様、全行同じフォントサイズ）

4. **背景グラデーション（追加スコープ）**: Desktopの `.fs-overlay` 背景（`components.css:1764-1776`）は `linear-gradient(135deg, color-mix(in srgb, var(--fs-bg-1) 30%, #0e0e1a), color-mix(in srgb, var(--fs-bg-2) 30%, #0e0e1a))`、track変更時に `transition: background 1.2s ease`。`SidecarBackgroundGradient.mixedStop(from:ratio:base:)` で同じ色ミックス計算を移植し、`SidecarAmbientBackground` という新規Viewで2ストップの `LinearGradient(.topLeading → .bottomTrailing)`（135degの近似）として描画。2色の入力は既存の `ArtworkPaletteExtractor` に `swatch1`/`swatch2`（彩度ブーストした生の左右平均色、ダークニング前）を追加して取得。パレット抽出は `SidecarScreen` の `.task(id: model.sidecarArtworkId)` で artworkId 変更時のみ実行（tickごとの再計算なし、perf制約を維持）。

## Alternatives considered

- 背景グラデーションの2色を、既存の `ArtworkPlaybackPalette.top`/`bottom`（NowPlayingView用にすでに42%+3%でダークニング済み）からそのまま使う案 → Desktopのcolor-mix比率（30%/70%）と二重にダークニングされてしまい正確な移植にならないため、ダークニング前の `swatch1`/`swatch2` を新規追加する方式にした。
- `SidecarArtworkView` の曖昧一致（`resolvedArtworkId`、タイトル/アーティストでのライブラリ検索）ロジックをパレット抽出でも再利用する案 → 二重実装を避けるため見送り、`model.sidecarArtworkId`（directiveの明示的artworkId）がある場合のみパレット抽出する簡易版にした。曖昧一致のみで解決するケース（デスクトップが `artworkId` を送らない場合）は背景がデフォルトの近黒グラデーションにフォールバックする。

## Constraints / Gotchas

- `SidecarArtworkLayout`/`SidecarLyricsMotionPolicy`/`SidecarBackgroundGradient` はいずれも `SidecarDirective.swift` に純関数として集約し、`UX-Music-MobileTests/SidecarLayoutMotionTests.swift` でTDD（Red→Green）。
- 歌詞行の `.animation(value: activeIndex)` はperf制約（`SidecarActiveLineUpdatePolicy` による change-gated 更新、固定アンカーの `TimelineView`）を変更していない — アニメーションパラメータのみ追加。
- `xcrun simctl io screenshot` はデバイスがランドスケープ方向にジオメトリ更新されていても素のフレームバッファはポートレート寸法で返ってくる場合があるため、検証時は `sips -r -90` で回転してから確認した（アプリ自体は正しくランドスケープ表示している）。
