# tvOS: 無操作30秒でUI・ジャケットが消える問題と、歌詞ステージのSidecar準拠化

## Decision

### 1. アンビエントは「レイアウト差し替え」から「クロームのフェード」に変更

実機報告:「操作を止めてから30秒程度経つと背景だけが残り、UIやジャケットが消えてしまう」。

原因は不具合ではなく**設計そのもの**だった。`TVNowPlayingView.content(ambient:)` は
`ambient == true` のとき通常レイアウト（`TVNowPlayingArtworkLayout` /
`TVNowPlayingLyricsLayout`）を丸ごと捨て、画面下部にタイトル・アーティスト・現在行だけを
小さく置く `TVAmbientOverlay` に差し替えていた。さらに同時に背景ウォッシュ
（`TVNowPlayingAmbientBackground`）が `opacity 0.3 → 0.18`・`blur 70 → 90` まで後退するため、
10フィート離れたソファからは「背景のグラデーションだけが残った」ようにしか見えない。
`TVAmbientStateMachine.idleTimeout = 30` 秒と報告の「30秒程度」も一致する。

そこで**アンビエントの意味を再定義**した。アートワーク・タイトル・歌詞は出したまま、
消すのは操作系クローム（トランスポートボタン、シークバーと時刻ラベル）だけにする。
数値は純粋 enum `TVAmbientPresentation`（`UX-Music-TV/TVAmbientPresentation.swift`）に集約し、
TDDで固定した:

- `contentOpacity(ambient:)` — アンビエント時 `0.82`。**0にはならない**ことをテストで固定
  （今回の不具合の回帰ガード）。
- `chromeOpacity(ambient:)` — アンビエント時 `0`。フェードは1.2秒。
- `driftOffset(ambient:secondsSinceAmbientStart:)` — 後述の焼き付き対策。

`TVAmbientStateMachine`（いつアンビエントに入るか）には手を入れていない。今回追加したのは
「アンビエントがどう見えるか」だけで、`next`/`exitCommand` の既存テストはそのまま通る。

### 2. 焼き付き対策のドリフト

アートワークを出し続ける以上、有機ELパネルに同じ絵が居座る。元のアンビエントが画面を
ほぼ空にしていた正当な理由はこれだと判断し、代わりに**コンテンツブロック全体を
ゆっくり動かす**方式に置き換えた。`driftOffset` は周期120秒・振幅28ptのリサージュ
（縦は横の2倍周波数・半振幅の8の字）。`secondsSinceAmbientStart == 0` で必ず `.zero` を返すので、
アンビエントに入る瞬間にレイアウトが飛ばない。負の経過時間（クロックずれ）も
`max(0,…)` でクランプ。

### 3. アンビエント中のトランスポートボタンは `.disabled`

`opacity(0)` だけではtvOSのフォーカスツリーに残るため、見えないボタンにSelectが刺さって
再生が勝手にトグルされうる（差し替え方式ではボタンごとView階層から消えていたので
この問題は存在しなかった）。`.disabled(ambient)` を併用してフォーカス対象から外した。
レイアウトは維持されるので、通常表示に戻るときのガタつきもない。

### 4. 歌詞表示をSidecar（＝Desktopフルスクリーン）準拠に作り直し

`TVSyncedLyricsFocusView`（前行・現在行・次行の3行固定ウィンドウ＋ピンクのアクセントバー）を
廃止し、`TVLyricsStageView` を新設した。Mobileのサイドカー画面が
`progress/sidecar-lyrics-fade-and-bilingual.md` で既に解決していた以下を取り込む:

- **行独立モーション**: リスト全体をスクロールするのではなく、各行が自分の `y` を持って
  独立に動く（Desktop `applyLyricsMotion` 1:1）。アクティブ行はペイン高さの35%に固定、
  前後は自身の高さ＋ギャップの累積和。0.8秒 / 距離×0.04秒のスタッガ、CSS既定の
  `ease` タイミングカーブ。
- **`[間奏]` マーカーの空白化**: `SidecarLyricsDisplay.text(for:)`（Desktopの `fsDisplayText`）
  経由。従来のTV実装は生テキストをそのまま出していた。
- **和訳（バイリンガル）**: `/v1/remote/lyrics` の `translationContent`/`translationFormat` を
  `SidecarLyricsTranslationMerge` でペアリング。同一ブロック内に縦積みなので同じ
  オフセット・遅延に乗り、行高さ計測もブロック全体で行われる。
- **端フェード**: `SidecarLyricsEdgeFade`（上0–20%・下60–100%のイーズドランプ）を `.mask()`。
- **配色**: 非アクティブ `white 0.45` / アクティブ `white` の二値スワップ、
  `scale(1.091)`（leading起点）、`text-shadow` 相当の白グロー。ピンクのアクセントバーは廃止
  （Desktopに存在しないため）。

タイポグラフィのみTV用に拡大し、`TVLyricsStageMetrics` に名前付き定数として切り出した
（本文40pt / 和訳28pt / 行間28pt）。「Sidecarの28ptより大きい」「和訳は本文より小さい」は
テストで固定している。

### 5. 共有コード `Core/LyricsStageKit.swift` の新設

上記の純粋ロジックは元々 `Services/SidecarDirective.swift`（iOS専用・UIKit依存）と
`Views/SidecarScreen.swift`（`private`）に埋まっていて、tvOSターゲットから参照できなかった。
`SidecarLyricsDisplay` / `SidecarLyricsTranslationMerge` / `SidecarLyricsMotionPolicy` /
`SidecarLyricsLayout` / `SidecarActiveLineUpdatePolicy` / `SidecarLyricsEdgeFade` を
`Core/LyricsStageKit.swift`（Foundation + SwiftUIのみ）へ移し、`UX-Music-Mobile` と
`UX-Music-TV` の両ターゲットに登録した。`LyricsTranslationMerger.swift` もTVターゲットに追加。

`SidecarLyricsLayout.tops` には `interBlockGap` 引数（既定値はDesktopの16pt）を追加し、
TVだけ28ptを渡せるようにした。

### 6. `TimelineView` のアンカー固定

`TVNowPlayingView` の1秒ティックは `.periodic(from: .now, by: 1)` だった。このティックは
`ambientState`（および今回追加の `ambientSince`）を書き、その値をbodyが読むため、
毎ティックで `TimelineView` が作り直され、そのたびにスケジュールが `.now` に再アンカーされる
——`progress/sidecar-poll-tick-cpu-leak.md` で特定済みのフィードバックループそのもの。
`@State private var tickAnchor = Date()` に固定した。

## Alternatives considered

- **アンビエントモード自体を削除**: 見送り。無操作放置は「音楽をかけっぱなしにする」TVでは
  常態で、焼き付き対策と操作系の引っ込めには意味がある。ユーザーの不満は「消えること」で
  あって「静かになること」ではないと解釈し、機能の意図は残した。
- **アンビエント時にジャケットだけ残して歌詞を消す**: 見送り。歌詞同期表示はこの画面の
  主機能であり、放置中こそ読まれる。消す理由がない。
- **`SidecarLyrics*` の型名を中立な名前にリネーム**: 見送り。参照は4ファイル65箇所あり、
  挙動を変えないリネームでMobile側にリスクを持ち込む価値がないと判断。
  `Core/LyricsStageKit.swift` の先頭に「Sidecarは初出画面に由来する歴史的な名前で、
  現在はtvOSとも共有」と明記して代替した。
- **TV側に `tops`／モーション定数をコピーする**: 却下。Desktop準拠の算術が2実装に増える。

## Constraints / Gotchas

- `TVLyricsStageView` は `GeometryReader` ベースで縦方向にgreedy。`TVNowPlayingLyricsLayout`
  の `HStack` はこれにより画面高いっぱいまで伸びる（従来はコンテンツ高で決まっていた）。
  アートワークは `alignment: .top` 固定なので位置は変わらない。
- `TVLyricsStageView` の0.2秒ティックも `@State` アンカー固定済み。アクティブ行が実際に
  変わったときだけ `@State` に書く（`SidecarActiveLineUpdatePolicy`）ので、`ForEach` の
  再diffは行送りのタイミングだけ。
- アクティブ行の判定は `SidecarLyricsMotionPolicy.activeIndex`（イントロ中は `-1`）であって
  `LRCParser.activeLineIndex`（0にクランプ）ではない。Desktop準拠のためで、
  廃止した `TVSyncedLyricsFocusView` は後者を使っていた。
- `UX-Music-TV` ターゲットのファイル追加は `project.pbxproj` を直接編集している
  （`PBXBuildFile` / `PBXFileReference` / グループ / `PBXSourcesBuildPhase` の4箇所）。
  Xcodeを開かずにファイルを足す場合は4箇所すべて必要。
