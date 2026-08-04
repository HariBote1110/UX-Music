# UX Music Mobile: 再生画面のスワイプ被覆バグ修正と歌詞画面の環境光デザイン刷新

## 決定事項

### 1. サイドパネル被覆率（`nowPlayingSidePanelCoverage`）

- `NowPlayingView.swift` の座標系:
  - `NowPlayingAmbientBackground` は `.ignoresSafeArea(.all)` で画面全体（ステータスバー帯・
    ホームインジケータ帯を含む）に描画される。これは意図的な設計（コメント参照）で、
    ambient グラデーションを `.clipped()` パネルの外側に置くことでセーフエリアまで届かせている。
  - 一方 Queue / Favourites / PlaybackSettings パネルは `GeometryReader` の中（セーフエリア
    準拠の座標系）にあり、`.background(Color.black)` はセーフエリア外の帯には届かない。
  - 結果として、サイドパネル表示中〜スワイプ中に画面上下の帯だけ ambient グラデーションが
    「侵食」して見えるバグが発生していた。
- 修正: 純関数 `nowPlayingSidePanelCoverage(page:horizontalDrag:width:) -> CGFloat` を追加し、
  既存の `displayStripOffset`（ドラッグのラバーバンド込みオフセット）から
  `abs(offset + w) / w` を `[0, 1]` にクランプして算出する。
  - `page == .playbackSettings` は常に `1`（全画面オーバーレイのため）。
  - `width <= 1` は `0`（初期レイアウト未確定時の安全策）。
- `GeometryReader` 内の `ZStack(alignment: .top)` の最背面（ストリップより背面・
  full-screen ambient background より前面のレイヤーとして機能する）に
  `Color.black.opacity(coverage).ignoresSafeArea().allowsHitTesting(false)` を追加。
  ドラッグ追従とスプリングアニメは既存の `page` / `horizontalDrag` の状態変化にそのまま
  追従するため、被覆レイヤー側に個別のアニメーション定義は不要。
- テスト可能にするため `NowPlayingPage` / `stripBaseX` / `displayStripOffset` /
  `nowPlayingSidePanelCoverage` を `private` から `internal` に変更した
  （`UX-Music-MobileTests/NowPlayingCoverageTests.swift`）。

### 2. 歌詞画面（`NowPlayingLyricsScreen.swift`）の環境光デザイン刷新

- 背景共有: `NowPlayingAmbientBackground` / `nowPlayingFallbackAccent` /
  `NowPlayingNavIconButton` を `internal` 化し、`NowPlayingView.swift` から
  ファイル移動せずに再利用。`NowPlayingView` の `fullScreenCover` から
  `ambientPalette`（`@State`）を歌詞画面へ渡すことで、再生画面と同じ配色のまま
  遷移できる（アートワークからの再抽出待ちが発生しない）。
- コントラスト確保のため、ambient background の上に `Color.black.opacity(0.35)` を重ねた。
- 同期歌詞（LRC）: レイアウトジャンプを避けるため全行フォントサイズは 26pt 固定とし、
  アクティブ行は `weight: .bold` / 不透明・非アクティブ行は `weight: .semibold` /
  `opacity(0.35)` / `blur(radius: 0.8)` で差をつけた。
- エッジフェード: `ScrollView` に `.mask(LinearGradient(...))` を適用し、上12%・下18%を
  フェードアウト。フェード係数のロジック自体は純関数 `nowPlayingLyricsFadeOpacity(fraction:)`
  としてテスト化した（実際の `.mask` はグラデーション記述で同じ帯幅を再現している）。
- 上下スペーサーとして `geo.size.height * 0.35` を先頭・末尾に置き、最初/最後の行も
  画面中央に来られるようにした。
- 行タップでシーク: `model.player.seek(to:)`（既存 API、`NowPlayingProgressSection` の
  スクラバーと同じもの）を使用。シーク対象時刻決定は純関数 `nowPlayingLyricsSeekTime(for:)`
  としてテスト化。
- 自動スクロール一時停止: `DragGesture` でユーザースクロールを検知し `lastUserScrollAt`
  （`Date?`）を更新。`TimelineView` の 0.05 秒ごとの再描画で
  `context.date.timeIntervalSince(lastUserScrollAt)` を計算し、
  純関数 `nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll:)`
  （3秒未満なら自動追従を止める）で判定する。
- ナビゲーションバーを廃止し、`NowPlayingNavIconButton` による「×」の浮きボタンのみ
  右上に配置（`NowPlayingView` の閉じるボタンと統一感を持たせた）。

### 3. サイドパネルの角丸カード化（スワイプ中の直角見切れ対策）

- 実機で横スワイプすると、隣から入ってくる Queue / Favourites / PlaybackSettings パネルが
  「直角の板」のまま見切れて悪目立ちする問題があった。
- 修正: `HStack` ストリップ内で `NowPlayingQueuePanel` / `NowPlayingFavouritesPanel` /
  `NowPlayingPlaybackSettingsPanel` を `.frame(width:height:)` した直後に
  `.clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))` を適用し、
  さらに同形の `.strokeBorder(.white.opacity(0.08), lineWidth: 0.5)` を overlay して
  カードのエッジを引き締めた。パネル自体の背景色（`Color.black`）は変更していない。
- 定位置（`coverage == 1`）では背面の黒被覆レイヤーと同色になるため角丸は視認できず、
  スワイプで隣のパネルが動いている間だけ角丸カードとして見える、という既存の
  coverage 被覆の仕組みをそのまま利用している（ロジック変更なし）。
- メイン再生パネル（`NowPlayingPlayingShell`）は環境光が透過するデザインのため
  クリップ対象から意図的に除外した。
- リスト行も同様に直角のブロック感があったため、`.listRowBackground` を単色の矩形から
  `RoundedRectangle(cornerRadius: 12, style: .continuous)` を左右 8pt インセットして
  塗った角丸カードに変更し、`.listRowSeparator(.hidden)` を添えてセパレーター線が
  角丸カードの見た目を破らないようにした（Queue / Favourites 両パネル）。

### 4. PlaybackSettings（EQ）パネルのドラッグ追従シート化

- 従来はメイン画面での上方向ドラッグ終了時に `ty < -52` の閾値判定で `page = .playbackSettings`
  へ切り替え、`.transition(.move(edge: .bottom).combined(with: .opacity))` で出現させていた。
  指の動きに追従せず、離した瞬間に急に湧いて出る／フェードが安っぽいという課題があった。
- 修正: パネルの出現を「指の持ち上げ量に応じて下端から迫り上がるシート」として再実装。
  - 新規 `@State private var settingsDragOffset: CGFloat`（メイン画面での縦ドラッグの
    生の translation.height、上方向のみ負値として反映。下方向のドラッグ量はここでは
    `0` に丸め、既存の下スワイプ dismiss 判定を壊さないようにした）。
  - 純関数を4つ追加（`NowPlayingView.swift`、`NowPlayingCoverageTests.swift` にテスト）:
    - `nowPlayingSettingsSheetProgress(dragTranslationY:height:) -> CGFloat`
      （上方向ドラッグ量 ÷ 画面高さ、`[0,1]` にクランプ）
    - `nowPlayingSettingsSheetOffsetY(progress:height:) -> CGFloat`
      （`h * (1 - progress)`。0 = 画面外に完全に隠れる、`h` = 完全に持ち上がる）
    - `nowPlayingSettingsSheetDarkness(progress:) -> CGFloat`
      （`progress * 0.5`。背面の暗さは最大 0.5 に留め、シート自体が常に前面として
      明るく見えるようにした）
    - `nowPlayingSettingsSheetShouldOpen(progress:) -> Bool`（`progress > 0.22` で確定）
  - パネルは `page == .playbackSettings` のときだけでなく**常に描画**する方針に変更した
    （`.transition` を廃止）。理由: `if` 条件でパネルの出し入れを行うと、`page` の状態変化が
    瞬時に起こる SwiftUI の性質上、閉じるアニメーション中に条件が先に `false` になって
    ビューが即座に消えてしまい、スプリングで下に戻る演出ができなかった。常時描画した上で
    `.offset(y:)` にのみ progress を反映し、`.allowsHitTesting(page == .playbackSettings)`
    で「完全に開いている時だけ操作を受け付ける」形にすることで、開閉どちらのアニメーションも
    自然に追従するようにした。
  - 背面の暗さは既存の `nowPlayingSidePanelCoverage`（safe-area 帯の被覆専用）とは別レイヤー
    として `Color.black.opacity(nowPlayingSettingsSheetDarkness(progress:))` を追加した
    （既存の coverage ロジックには手を入れていない）。
  - 上端にグラバーバー（`Capsule` 幅36×高さ5、白 opacity 0.3）を追加し、シートらしい
    見た目にした。
  - リリース時の判定は `handleStripDragEnded` 内の縦軸ブランチで
    `nowPlayingSettingsSheetShouldOpen(progress:)` を使うよう変更し、開かない場合は
    `settingsDragOffset` をスプリングで 0 に戻す。下スワイプ dismiss（`ty > 68`）は
    従来どおり維持。

## 検討したが採用しなかった案

- アクティブ行を `scaleEffect` で拡大する案 → 初回実装時点では不採用。フォントサイズを
  可変にすると LazyVStack の行高が変わり、スクロール位置がガタつく（レイアウトジャンプ）
  ため、サイズは全行固定にして weight / opacity / blur のみで強調した。
  - **のちに撤回**: 「5. 歌詞行の Apple Music 級トランジション」で `scaleEffect` を
    再導入した。理由は下記参照（`scaleEffect` はレンダリング変換のみで `LazyVStack` が
    親に報告する intrinsic size を変えないため、フォントサイズ可変時とは異なりレイアウト
    ジャンプを起こさない）。

## 5. 歌詞行の Apple Music 級トランジション（YouTube 16:9 カード対応と同時実装）

### 5-1. YouTube 動画カードの 16:9 化（`NowPlayingArtworkBlock`）

- `NowPlayingView.swift` の `NowPlayingArtworkBlock.body` で、外枠の `Color.clear` に
  かけていた `.aspectRatio(1, contentMode: .fit)` を
  `.aspectRatio(song.isYouTube ? 16.0/9.0 : 1, contentMode: .fit)` に変更。
  横幅は既存どおり `.frame(maxWidth: 340)` で共通のまま、縦だけが曲種別で変わる。
  角丸・影・枠線・サムネイルプレースホルダは既存の `.overlay` / `.clipShape` /
  `.shadow` チェーンをそのまま利用（変更なし）ため個別に作り直していない。
- ローカル曲⇄YouTube 曲の曲送りでカードの縦横比が切り替わる際のアニメーションは、
  ブロック全体に `.animation(.spring(response: 0.45, dampingFraction: 0.85), value: song.isYouTube)`
  を付与して実現。上下の空間は親 `VStack`（`NowPlayingPlayingShell`）側の `Spacer` が
  そのまま吸収するため、カード側にレイアウト補正のロジックを追加する必要はなかった。

### 5-2. 同期歌詞のスクロール・行トランジション（`NowPlayingSyncedLyricsScroll`）

- スクロール用スプリングを `response: 0.45, dampingFraction: 0.85` から
  `response: 0.6, dampingFraction: 0.8` に変更（Apple Music 寄りの、より「ゆったり
  持ち上がる」タイミングに調整）。`ScrollViewReader.scrollTo` と行のスタイル変化
  （後述）の両方が同じ `Self.autoScrollSpring` を参照するようにし、スクロール位置と
  行の見た目が必ず同じテンポで遷移するようにした。
- アクティブ行に `.scaleEffect(isActive ? 1.05 : 1, anchor: .leading)` を追加し、
  各行の `Button` に `.animation(Self.autoScrollSpring, value: isActive)` を付けて
  scale / foregroundStyle / blur を同一スプリングで同時に遷移させる
  （`withAnimation` でラップされたスクロールと合わせて「行がふわっと持ち上がる」
  見た目になる）。
- パフォーマンス対策として、blur は従来「非アクティブ行は常に 0.8」だったのを、
  アクティブ行から `blurNeighbourRadius`（6行）以内だけ `2.2` を掛け、それ以外は
  `0`（blur なし）にした。`LazyVStack` は一度測定した行を保持し続けるため、長い
  歌詞ファイルで全行に blur を掛け続けると GPU コストが線形に増える懸念があり、
  近傍だけに絞ることで軽減した。

### 5-3. ScrollViewReader を維持した判断（offset ベース自前スクロールへの切替は見送り）

- タスク指示では `scrollPosition`（iOS17+）やオフセットベースの自前スクロールへの
  切替も検討してよいとされていたが、今回は既存の `ScrollViewReader.scrollTo` +
  `withAnimation(spring)` の構成を維持した。
  - 理由: 現状の実装は `scrollTo(id:anchor:.center)` を spring でラップしており、
    実機/シミュレータでの目視確認（本チケットでは tap 注入が不安定だったため未実施、
    別セクション「罠」参照）は行えなかったが、コード上は「対象行の `id` に対して
    align: .center で遷移」という単純な構成であり、荒さの主因になりやすい
    「頻繁な `scrollTo` 呼び出しの割り込み」は `onChange(of: active)` 経由の
    1件のみで、ドラッグ中は `lastUserScrollAt` によって自動スクロール自体が
    止まるため競合しない。実装コストと壊れるリスク（`scrollPosition` は
    `LazyVStack` + 可変長行という現在の構成との相性検証が別途必要）に対して、
    スプリングの response/dampingFraction 調整と行トランジション統一だけで
    体感の大部分は改善できると判断し、オフセット自前実装への切替は見送った。
    将来 `scrollTo` の補間の粗さが実機で問題になった場合の次の一手として
    `scrollPosition(id:anchor:)` への切替を検討する、という形で先送りにした。

## 罠・非自明な制約

- `NowPlayingAmbientBackground` を `.ignoresSafeArea(.all)` で複数箇所に置く場合、
  必ず「どのパネルがセーフエリア準拠か」を意識すること。今回のバグはまさに
  「ambient background だけがセーフエリア外まで描画され、それを覆うはずのパネルが
  セーフエリア内にしか存在しない」というレイヤー構成の食い違いが原因だった。
- `@testable import` 越しにテストから触れるためには `private` ではなく最低でも
  `internal`（デフォルト）にする必要がある。今回変更した
  `NowPlayingPage` / `stripBaseX` / `displayStripOffset` /
  `nowPlayingSidePanelCoverage` / `nowPlayingFallbackAccent` /
  `NowPlayingAmbientBackground` / `NowPlayingNavIconButton` はすべてこの理由で
  アクセスレベルを変更している。
- 新規 Swift テストファイルは Xcode プロジェクトファイル
  （`UX-Music-Mobile.xcodeproj/project.pbxproj`）に
  `PBXBuildFile` / `PBXFileReference` / グループ内の参照 / `PBXSourcesBuildPhase`
  の4箇所へ手動登録しないとビルド対象に含まれない。
- `mcp__Claude_Code_iOS_Simulator__control` の `tap` / `touch_path` によるアプリ内
  リスト行タップが、iPhone Air シミュレータ（E7DC188E-...）上で今回まったく反応しない
  事象が発生した（アルバム→曲一覧への遷移タップは成功したが、曲行タップで再生開始が
  一度も起こらなかった）。座標・タイミング（`sleep` 挿入）・`tap` と `touch_path`
  の両方を試したが再現せず、原因切り分けはできていない。この事象により本セクションの
  変更（16:9 カード・歌詞行トランジション）は `xcodebuild build`/`test` の green は
  確認できたが、シミュレータでの目視確認（スクショ/録画）は完了できていない。次回は
  `xcrun simctl io <udid> recordVideo` で操作全体を録画しつつ実機相当の Simulator.app
  を前面化した状態で試す、または `idb ui tap` 等の別経路を検討すること。
