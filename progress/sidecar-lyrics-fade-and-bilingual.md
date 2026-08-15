# サイドカー画面の歌詞ペイン端フェード・左カラム余白調整・和訳（バイリンガル）対応

## Decision

ユーザー評価「歌詞モーションのパリティは満足、追加の見た目調整」を受けて `SidecarScreen.swift` に3点を追加した。

1. **歌詞ペインの端フェード**: Desktopのフルスクリーン歌詞コンテナ（`src/renderer/styles/components.css:2072-2078`、`.fs-lyrics-container` の `mask-image: linear-gradient(to bottom, transparent 0%, black 8%, black 70%, transparent 100%)`）が既に存在したため、そのストップ値をそのまま `SidecarLyricsEdgeFade`（`.mask()` に渡す `LinearGradient`）として1:1移植した。上端8%・下端30%という非対称な深さもDesktopの意図どおり保持している（iOS側で「対称に直す」判断はしていない）。

2. **左カラムの余白調整**: アートワーク列とタイトル/アーティスト/アルバムのブロック間、および2カラム間（アートワーク列⇔歌詞ペイン）が間延びしていた問題を `SidecarLayoutSpacing` の名前付き定数群で調整した。
   - 列間: `40pt → 20pt`
   - アートワーク列の幅比率: `40% → 30%`（列自体が大きすぎて中でアートワークが浮いていたのを解消）
   - アートワーク⇔情報ブロック間: `20pt → 16pt`
   - タイトル/アーティスト/アルバムの行間: `6pt → 8pt`
   - 外周パディング: `32pt → 28pt`、下端クリアランス: `56pt → 48pt`
   スクリーンショットを2回反復し、2カラムが一体の構成として読めるところまで詰めた。

3. **和訳（バイリンガル）対応**: `RemoteLyricsPayload` が既に持つ `translationContent`/`translationFormat` を `SidecarScreen.reloadLyricsIfNeeded()` で読み、既存の `LyricsTranslationMerger`（`NowPlayingLyricsScreen` が使っているのと同じ純関数）でペアリングした。サイドカーは `LyricsFileStore` を経由せず `/v1/remote/lyrics` を都度フェッチする画面のため、「どのマージ関数を使うか」の判定を `AppModel.localBilingualLyricsDisplay(for:)`（ファイル存在で判定）とは別に、ペイロードの `translationFormat` 文字列で判定する `SidecarLyricsTranslationMerge.merge(primary:translationContent:translationFormat:)` を新設した（`Services/SidecarDirective.swift`）。
   - 描画スタイルはDesktopの `.fs-line-bilingual`/`.fs-line-translation`（`components.css:2181-2190`）に準拠: 同じ行ブロック内に縦積み・`gap: 4px`、和訳フォントサイズは本文の0.7em相当（同期ペイン: 28pt→20pt、プレーンテキストペイン: 18pt→13pt）、色は `rgba(255,255,255,0.5)` 固定（アクティブ/非アクティブで変化しない — Desktop通り）。
   - 和訳は本文と**同じ**Viewブロック内（同じ `offset`/`scaleEffect`/`.animation`）に載せているため、別アニメーションエンティティにはならない。`SidecarLineHeightKey` の高さ測定もブロック全体を測るため、和訳の有無で行の高さが変わっても `SidecarLyricsLayout.tops` の累積レイアウトは変更なしに追従する。
   - プレーンテキスト（非LRC）パスにも `SidecarBilingualPlainLine` を新設し、`LyricsTranslationMerger.mergePlainWithJaTxt` で同様にペアリング。

## Alternatives considered

- 和訳のペアリングロジックを `SidecarScreen.swift` 内にベタ書きする案 → `LyricsTranslationMerger`（`Core/LyricsTranslationMerger.swift`）が既にタイムスタンプ一致/位置一致/インタールード除外のロジックをテスト済みで持っているため、新規実装はせず「どのマージ関数を呼ぶか」という薄い判定層 (`SidecarLyricsTranslationMerge`) だけを新設し、二重実装を避けた。
- 和訳の文字色をアクティブ行で明るくする案（`NowPlayingLyricsScreen` の `isActive ? 0.6 : 0.28` 的な二値）→ サイドカーはDesktopの見た目に忠実であることが優先スコープなので、Desktop CSSどおり固定 `rgba(255,255,255,0.5)` を採用した。iOSの別画面（`NowPlayingLyricsScreen`）が独自にアクティブ強調を追加しているのは承知の上で、サイドカーはDesktop準拠を優先する既存方針（歌詞モーション移植と同じ判断軸）を踏襲。

## Constraints / Gotchas

- `scripts/sidecar_stub_server.py` に `--translation-lrc-file` を追加（`translationContent`/`translationFormat: "lrc"` を `/v1/remote/lyrics` に付加）。実機なしでバイリンガル表示を検証できる。
- `SidecarLyricsTranslationMerge` は `UX-Music-MobileTests/SidecarLayoutMotionTests.swift` にTDDで追加（欠落/空文字時のnil化、lrc形式のタイムスタンプ一致、txt形式の位置一致、フォーマット欠落時のフォールバック、間奏行への和訳非付与）。
- 全体テストスイート: 564 passed / 1 failed（`LocalizationCatalogCompletenessTests.testIOSCatalogHasCompleteTranslations` — 既知の無関係な既存失敗、`tv.relay.error.unknown` キー欠落） / 8 skipped。

## 追記（シークバー余白の追い込み・歌詞フェードのDesktop乖離）

ユーザーから2点の追加フィードバックを受け、`SidecarScreen.swift` をさらに調整した。

1. **シークバー周りの余白**（「シークバーは重要じゃないので余白を詰めて」）: `SidecarLayoutSpacing.contentBottomClearance` を `48pt → 24pt` に短縮し、`progressBar` 自身の `.padding(.horizontal, 28→20)`／`.padding(.bottom, 14→8)` も名前付き定数化（`progressBarHorizontalPadding`/`progressBarBottomPadding`）して縮小した。バーの太さも `3pt → 2pt`、時刻ラベルのフォントサイズも `11pt → 10pt` に落とし、バーが画面端に控えめに張り付く「重要でない要素」として読めるようにした。

2. **歌詞フェードの緩化**（「スパッと切れる感じがある、もうじわじわ消えてほしい」）: `SidecarLyricsEdgeFade` は元々Desktopの `.fs-lyrics-container` マスク（`transparent 0% → black 8% → black 70% → transparent 100%`）を1:1移植したものだったが、サイドカーの歌詞ペインでは短い直線的ランプが「唐突に切れる」ように見えることが分かった。**この画面はここでDesktopの見た目から意図的に乖離する**: 上端ランプを `0–8%` → `0–20%`、下端ランプを `70–100%` → `60–100%` に伸ばし、両端とも直線1段ではなく `0 / 0.08 / 0.30 / 0.65 / 1.0` の不透明度を4〜5点打つイーズドランプにして、視覚的に緩やかな溶暗に近づけた。

検証は `scripts/sidecar_stub_server.py --lrc-file` （密なLRC）をスタブとして使い、UXM-Verifyシミュレータ（landscape固定）で `git stash` によるbefore/afterのスクリーンショット比較を実施。上端行が完全に見切れず徐々に薄くなること、バーが画面端に寄って主張しなくなったことを目視確認した。

### Gotchas
- ローカルのDesktop（`UX-Music.app`）がポート `8765` (`ultraseek-http`) を掴んでいると、スタブサーバーがそのポートで待ち受けても実際のリクエストはDesktop側の本物のAPIに刺さり `401 Unauthorized` になる（スタブは常に200を返すため、切り分けの決め手はレスポンスコード）。スタブは別ポート（例: `8799`）で起動すること。
- `installDebugSidecarHostHookIfRequested()` は環境変数を読むのがプロセス起動時の一度きりなので、`xcrun simctl launch` を単に再実行してもアプリが既に前面稼働中だと環境変数が反映されない。`xcrun simctl terminate` で確実にプロセスを終了させてから `launch` すること。
- MCPシミュレータの `screenshot` はアプリがランドスケープを強制していてもデバイスの物理フレーム（ポートレート）をそのまま返す（コンテンツだけ回転して描画される）。目視確認用には `xcrun simctl io <udid> screenshot` の生PNGを `sips -r -90` で回転させると正しい向きになる。
