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

## Decision（2026-08-15 追記: 歌詞モーション完全パリティ化 — 行別絶対位置レイアウトへの再実装）

上記「3. 歌詞モーション」で移植したパラメータ（`ANCHOR_RATIO`/`MOTION_DURATION_MS`/`MOTION_DELAY_STEP_MS`/`activeLineScale`）は正しかったが、それらを**どう使うか**がDesktopと根本的に異なっていた。ユーザー評価「悪くはないが良くもない」を受けて、Desktop実装を全面的に読み直し、完全パリティで再実装した。

### 抽出したDesktop仕様（`src/renderer/js/features/fullscreen-view.ts` / `src/renderer/styles/components.css`）

- **各行は独立して動く、スクロールしない**: `applyLyricsMotion`（`fullscreen-view.ts:392-426`）は各 `<p>` 要素に個別の `--fs-line-y`（`translateY`、絶対位置の `top`）を設定する。コンテナ自体はスクロールしない（`.fs-lyrics-inner.fs-lrc { position: relative; overflow: hidden }`、`components.css:2137-2142`）。
- **位置計算**: アクティブ行（`activeIndex`、なければ `0`）を `anchorY = lyricsEl.clientHeight * ANCHOR_RATIO(0.35)` に固定し、そこから前後の行を「自身の高さ + `INTER_BLOCK_GAP(16px)`」の累積和で並べる（`fullscreen-view.ts:411-416`）。高さは初回 `getBoundingClientRect()` で測定してキャッシュ（`cachedLrcHeights`）。
- **トランジション**: `transition-property: transform, opacity, color`、`duration` は通常 `MOTION_DURATION_MS(800ms)`／初期表示・リサイズ時のみ `0ms`（immediate）、`delay` は `abs(i - activeIndex) * MOTION_DELAY_STEP_MS(40ms)`（`fullscreen-view.ts:418-422`）。`transition-timing-function` の明示指定なし＝UA既定の `ease`（`cubic-bezier(0.25, 0.1, 0.25, 1.0)`）。
- **アクティブ判定**: `findLyricsIndex`（`fullscreen-view.ts:366-390`）は「時刻 `<=` の最後の行」だが、**最初の行の時刻より前は `-1`**（どの行もハイライトしない＝イントロ無音区間はアクティブ行なし）。最後の行以降は最終行のインデックス。200ms間隔の `setInterval`（`fullscreen-view.ts:124-132`）で毎回この判定を呼ぶ。オフセット/リード定数は一切なし（生の再生位置をそのまま比較）。
- **スタイル**（`components.css:2143-2162`）: フォントサイズ・太さは全行共通（`2.2rem`/`700`、アクティブでも変えない）、色はアクティブ `#fff`・非アクティブ `rgba(255,255,255,0.45)` の二値のみ（距離に応じたopacity減衰は存在しない）、アクティブのみ `scale(1.091)`（`transform-origin: left center`）と `text-shadow: 0 0 24px rgba(255,255,255,0.15)` のグロー。幅は `calc(100% / 1.091)` でスケール後もはみ出さないよう事前に確保。

### 旧実装（前回移植）の誤り

1. **最大の欠陥**: `ScrollView` + `ScrollViewReader.scrollTo(anchor:)` でリスト全体を1つのユニットとしてスクロールしていた。Desktopは行ごとに独立した `transform` アニメーションであり、「全体がスクロールする」動きはDesktopに存在しない。
2. **余分な装飾**: `opacity(forDistance:isActive:)` という距離ベースのopacityフォールオフ（`max(0.2, 0.55 - distance*0.08)`）を独自追加していたが、Desktopには存在しない（二値の45%/100%のみ）。フォントウェイトをアクティブ時のみ `.bold` に切り替えるのもDesktopにない（Desktopは常時700=bold）。
3. **タイミングのズレ**: `LRCParser.activeLineIndex` を流用しており、最初の行より前の時刻を `0`（先頭行）にクランプしていた。Desktopは `-1`（無ハイライト）。イントロ中に不要なハイライトが出ていた。

### 新実装

- `SidecarLyricsLayout.tops(heights:baseIndex:paneHeight:)`（純関数、`Services/SidecarDirective.swift`）: `applyLyricsMotion` の累積位置計算を1:1移植。`UX-Music-MobileTests/SidecarLayoutMotionTests.swift` でTDD。
- `SidecarLyricsMotionPolicy.activeIndex(in:at:)`（同ファイル）: `findLyricsIndex` を1:1移植（`-1` 前置き含む）。既存の `LRCParser.activeLineIndex`（他画面が意図的に `0` クランプを使う）とは別関数として新設し、他画面の挙動には触れていない。
- `SidecarSyncedLyricsList`（`Views/SidecarScreen.swift`）: `ScrollView` を廃止し、`GeometryReader` + `ZStack(alignment: .topLeading)` の中で各行に `.offset(y:)` を個別付与、`PreferenceKey` で行ごとの実測高さを収集して `SidecarLyricsLayout.tops` に渡す。アニメーションは `.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.8).delay(distance * 0.04)`（CSS既定の `ease` を明示的に再現）。パフォーマンス確保のため、計算上の `y` がペイン範囲 ± 400pt を超える行は描画自体をスキップ（Desktopにはこの概念はないが、SwiftUIは全行を常時レイアウトするコストがCSS/DOMより高いため、コスト境界として追加）。
- スタイルはDesktop CSS通りに単純化: 太さは常時 `.bold`、色は `.white.opacity(isActive ? 1 : 0.45)` の二値、アクティブのみ `scaleEffect(1.091, anchor: .leading)` と `.shadow(color: .white.opacity(0.15), radius: 24)`。距離ベースのopacity減衰・フォントウェイト切替は削除。

### 検証

- `SidecarLayoutMotionTests`（新規9ケース＋既存）・全体テストスイート（`LocalizationCatalogCompletenessTests` を除く）: 563 passed / 0 failed / 8 skipped。
- `scripts/sidecar_stub_server.py` に `--lrc-file` オプションを追加（従来は歌詞エンドポイントが常時404固定だった）し、20行の密なLRCフィクスチャで実機相当検証。1秒間隔の連続スクリーンショットで「行ごとに独立して動く」モーション、アクティブ/非アクティブの二値スタイル、開始前（`-1`）は最初の行の時刻ちょうどで初めてハイライトが付くタイミングを目視確認（`/private/tmp/.../scratchpad/motion_seq_*.png`、`still_*.png`）。
- パフォーマンス再計測（歌詞アニメーション中、iPhone 17 Pro シミュレータ）: RSS 319MB台で横ばい、CPU 2〜4%、20秒間の `BLSInvalidateFrameSpecifiersAction` は1件のみ。`progress/sidecar-poll-tick-cpu-leak.md` で修正したTimelineViewストームの再発なし。
