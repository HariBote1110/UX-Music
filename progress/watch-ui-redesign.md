# Watch UI 刷新（3ページ構成）

## Decision
- 試作段階だった Watch アプリの UI を watchOS 純正 Music アプリに寄せて刷新（2026-08-08）。
- ページ構成は **ライブラリ ⇄ 再生中 ⇄ キュー&音量** の3ページ横ページング（`WatchPage` に `.queue` を追加）。
- ライブラリ: 自作の青カプセルトグル（Songs/Albums）を廃止し、`List` + `NavigationLink` の掘り下げ構成（「曲」「アルバム」の2行）に変更。watchOS ではセグメント切替よりネイティブな作法。
- 再生中: 60×60 の前景アートワークを廃止し、キャッシュ済みアートワークを**全面背景**＋暗色スクリムに。アートワークのデコードキャッシュ（0.5秒 tick での再デコード防止）・Crown シークの debounce・`isSyncingCrownProgrammatically` ガード・42mm 向け `ScrollView` は既存機構をそのまま維持。
- 音量: SwiftUI ネイティブの音量ビューが watchOS SDK に存在しないため、`WKInterfaceVolumeControl(origin: .local)` を `WKInterfaceObjectRepresentable` でラップ（`WatchQueueVolumeView.swift` 内 `SystemVolumeControl`）。`.local` は Watch 自身の出力（本アプリは iPhone 経由でなく Watch 単体再生のため）。
- キューページの行タップは**現在のキューを同位置から再生するだけ**で Now Playing へ自動遷移しない（ライブラリ行のみ遷移）。
- Watch の UI 文言を日本語に統一（iOS 側と揃える。`routeError` 含む）。

## Alternatives considered
- (a) Digital Crown を音量に割り当ててシークを別 UI へ移す → 却下。Crown シークは純正 Podcasts/Music と同じ標準操作で、質を下げたくない。
- (b) メニューから音量画面を出す → 却下。1 操作深くなる。
- (c) 3ページ目に音量＋キュー → **採用**。純正 Music の構成と同型で、既存のページスワイプ構造と整合。

## Constraints / Gotchas
- `WatchSongRow` は `selectedPage: Binding` 依存をやめ `onSelect` クロージャに一般化（キューページからの再利用のため。遷移するかは呼び出し側の責務）。
- 行スワイプ（`swipeActions`）はページスワイプと競合するため引き続き禁止。削除は長押しコンテキストメニュー。
- 新規ファイル `WatchQueueVolumeView.swift` は `project.pbxproj` へ手動登録（Watch ターゲットの Sources のみ。アプリ／テストターゲットには不要）。
- `WatchAudioPlayerService.playbackQueue` は `@Published` の複製ではなく computed passthrough — `queue` の変化は必ず `currentSong`/`isPlaying` の更新を伴うため再描画はそちらが駆動する。

## 追記 (2026-08-08): 実使用フィードバックによる調整
- **Digital Crown をシーク→音量に変更**（ユーザー判断）。当初の検討では (a)「Crown を音量へ」を却下して (c) を採用したが、実際に触った結果メイン画面の Crown は音量の方が良いとの結論に。シークは代替 UI へ移さず**廃止**（前後スキップのみ残る。プログレスバーは表示専用）。純正 Music の Now Playing と同じ役割分担になった。
- Crown フォーカスは `WKInterfaceVolumeControl.focus()`（watchOS 6.0+）を `Coordinator` から一度だけ呼ぶ方式。`SystemVolumeControl` に `autoFocusesCrown` パラメータを追加して共有部品化（キューページは false、Now Playing は true）。
- **シャッフル/リピートをデスクトップ版 SVG（`random.svg`/`repeat.svg`）で大型化**。SVG はアセットカタログに `preserves-vector-representation` + `template-rendering-intent: template` でそのまま取り込めた（`currentColor` ストロークでも問題なし。actool 警告ゼロ、Assets.car 内の実ピクセルまで検証済み）。「1曲リピート」はデスクトップに変種がないため、リピートアイコン＋小さな「1」バッジで表現。
- 未再生時の背景はデスクトップ既定アートワーク（`RemoteDefaultArtwork`）を再生時と同じスクリムで全面表示（ユーザー要望）。

## 追記 (2026-08-08 第2ラウンド): 音量HUD・アイコンアニメーション・背景はみ出し修正
- **音量はインライン行をやめ macOS（Sequoia 以前）風の縦型オーバーレイ HUD に**（ユーザー要望）。行を足した結果ページが縦に溢れてスクロール化したため。Crown→音量は不可視の `SystemVolumeControl` が担い、表示は `AVAudioSession.outputVolume` の KVO（`WatchVolumeHUD.swift`）。変化時のみ表示・1.2秒でフェードアウト、`allowsHitTesting(false)` でレイアウト非干渉。
- **シャッフル/リピートの静的 SVG アセットは廃止し、SwiftUI `Path` + `StrokeStyle.dashPhase` アニメーションで Desktop の動きを移植**。静的画像では「ストロークがパスに沿ってスライドする」動き（Desktop の売り）は再現不可能。パラメータは Desktop `player-ui.ts` と同一（standard=100/exit=130/enter=-30、dashArray=[len, len*3]、退場200ms ease-in→無アニメーションワープ→再入場400ms cubic-bezier(0.16,1,0.3,1)、シャッフル下線120ms遅延、リピート上下弧逆方向）。パス長近似・オフセット計算は `Core/ModeIconAnimationMaths.swift` に純関数化しテスト11件（app/Watch 両ターゲットで共有）。
- **ページスワイプ時に背景ジャケットの断片が隣ページに見える問題の真因は `scaledToFill` の非クリップはみ出し**。paged `TabView` は遷移中に隣ページを描くため、フレーム＋`.clipped()` なしの fill 画像はページ境界を越えて見える。`GeometryReader`（自身に `.ignoresSafeArea()`）でページ実寸を取り、明示フレーム＋`.clipped()` で解決。
- **再生中画面の縦方向メトリクスは「再生中の状態」を基準に決める**。プログレスバー＋経過/残り時間ブロックは曲がある時だけ描画されるため、未再生時に収まっていても再生中に溢れる。~~現在値: 外側 `VStack` spacing 5 / `.padding(.horizontal, 12)` + `.padding(.vertical, 4)` / 再生ボタン 34pt~~ → **この固定値方式は 2026-08-09 の第3ラウンドで廃止**。詳細は下の追記を参照。

## 追記 (2026-08-09 第3ラウンド): 固定メトリクスを `ViewThatFits` の候補ラダーに置き換え（根本解消）

- **背景**: 第1・第2ラウンドともに「その時点で確認できたワーストケース（46mm・ルートエラー表示）」に対して spacing/padding/フォントサイズを手で数値調整する方式を取ったが、ユーザーから「それでもまだスクロールすることがある」という報告が繰り返された。固定値のハンドチューニングは原理的に破綻している: Apple Watch は 40/41/42/44/45/46/49mm の少なくとも6種類の画面高で出荷されており、さらに watchOS の Dynamic Type がユーザー操作で `.headline`/`.caption2` 等の行高を画面サイズと無関係に変える。加えてルートエラー行の有無でコンテンツ量自体も変わる。「40mm・最大文字サイズ・ルートエラーあり」でも収まりつつ「49mm Ultra・標準文字サイズ」で間延びしない、という単一の定数は存在しない。数値を締めれば大きい画面で余り、緩めれば小さい画面で溢れる — イタチごっこになるのは当然だった。
- **対策**: `WatchNowPlayingView.swift` の `content` を `ViewThatFits(in: .vertical)` に置き換え、`.roomy`→`.compact`→`.reduced`→(`.reduced` を `ScrollView` でラップした最終フォールバック) の4段階を用意。各段階は同じ `nowPlayingStack(_:)` を `NowPlayingMetrics`（spacing/padding/フォントサイズをまとめた純データ構造体）でパラメータ化しただけで、構造上の重複はない。`ViewThatFits` は実機・実際の文字サイズ・実際のコンテンツで各候補を実測し、最初に収まったものを採用する — 数値を先読みして決め打つのではなく、SwiftUI 自身に「本当に収まるか」を判定させる方式に転換した。
- **Crown フォーカスとの関係**: 候補1〜3（`.roomy`/`.compact`/`.reduced`）は意図的に `ScrollView` を含まない。watchOS はスクロール可能なコンテンツが存在すると Digital Crown をデフォルトでそのスクロールに割り当てるため、非表示の音量コントロールがフォーカスを取り損ねた場合に「スクロール可能な `ScrollView` が存在する」こと自体が Crown を音量から奪う経路になる。候補1〜3を `ScrollView` フリーに保つことで、この経路をフォーカスの信頼性に関係なく大部分のデバイス/文字サイズ/コンテンツの組み合わせで無効化した。最終候補（`.reduced` を `ScrollView` でラップ）のみ、行き場のない極端なケース向けにスクロールへ意図的にフォールバックする。
- **実機シミュレータ検証結果**（40/42/44/46/49mm・再生中状態・タイトル/アーティストを長文に固定して測定): ルートエラーなしでは 40/42mm が `.reduced`、44/46/49mm が `.compact` を選択。ルートエラーありでは 40mm のみ `ScrollView` フォールバックへ落ち、42〜49mm は引き続き `.reduced`（非スクロール）で収まった — ルートエラー行に対しても専用の小さめフォント（`NowPlayingMetrics.routeErrorFont`）を割り当てて折り返し行数を抑えたことが効いている。`.roomy` はどの実測でも選ばれなかった（実際のボタンのタップターゲット最小サイズなどにより `.compact` との差が期待ほど大きくなかったため）が、将来的に短いタイトル等でより余裕のあるケースが出た際の受け皿として残してある。
- **watchOS シミュレータでの Dynamic Type 検証は未対応と判明**: `xcrun simctl ui <udid> content_size <size>` は watchOS ランタイムで `Runtime does not support dynamic text` エラーとなり利用不可。拡大文字サイズでの実機検証はできなかった（iOS シミュレータと異なる制約）。
- **Crown フォーカスの堅牢化も同時実施**: `hiddenCrownVolumeControl` を 1×1/不透明度0.02 から 44×44（`.allowsHitTesting(false)` でタップは奪わない）に拡大し、`SystemVolumeControl` に `refocusTrigger`（ページ再表示のたびにインクリメント）を追加して「一度だけ `focus()` を呼ぶ」から「ページに戻るたびに再フォーカス要求する」方式に変更。ページ間スワイプでフォーカスが奪われた場合の復帰を狙ったもので、確定的な検証はできていないため仮説の域を出ないが、副作用のない改善として採用。
