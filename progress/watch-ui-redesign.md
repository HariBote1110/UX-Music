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
  - **→ この「副作用のない改善」という判断は誤りだった。下記・第4ラウンドで判明した致命的フリーズの直接の原因がこの変更だった。**

## 追記 (2026-08-09 第4ラウンド): キュー&音量ページでスワイプ・Crown が両方効かなくなる致命的フリーズを修正（リグレッション）

### 症状（実機ユーザー報告）
曲を転送済みの実機で、3ページ目「キュー&音量」（`WatchQueueVolumeView`）に入ると、横スワイプでの他ページへの復帰と Digital Crown の両方が完全に無反応になり、ユーザーがそのページに閉じ込められる。シミュレータの空ライブラリでは再現しないため、キューに実データが入っている必要がある。

### 再現方法
シミュレータの Application Support 配下（`library.json` / `Audio/` / `Artwork/`）に28曲分のダミー楽曲メタデータと、本番の `WatchTransferBridge.writeDownscaledArtwork` と同条件（長辺400px・JPEG品質0.6相当、実測20〜30KB/枚）の実JPEGアートワークを直接書き込み、実機と同じ「ライブラリ→曲→タップ→再生中→キューへスワイプ」という操作列で再現した（Apple Watch SE 3 40mm, watchOS 26.5 シミュレータ）。

### 検証した仮説と結果
1. **行アートワークの同期デコード**（`WatchSongRow` → `WatchArtworkThumbnail` が `body` 内で毎回 `Data(contentsOf:)` + `UIImage(data:)` を同期実行、`WatchNowPlayingView` にあるようなキャッシュがない）— **棄却**。フリーズしたプロセスを `sample <pid>` でサンプリングしたところ、2331サンプル中0件がJPEG/ImageIOのデコード経路にあった。100%が仮説2の経路に集中しており、アートワークデコードは今回のフリーズの原因ではない。ただし `WatchSongRow`/`WatchArtworkThumbnail` が非キャッシュ・同期デコードのままであること自体は実在する技術的負債であり、別件のフォローアップ候補として残す（本修正のスコープ外）。
2. **オフスクリーンの Crown フォーカスコントロールによる `focus()` 呼び出し** — **確定（真因）**。詳細は下記。
3. **`List` と paged `TabView` のジェスチャー競合** — **棄却**。フリーズ中は横スワイプだけでなく、キューリストの縦スクロールもタップも一切反応しなかった。ジェスチャー優先度の競合であれば少なくとも `List` 自身の縦スクロールは正常に動くはずで、そうならなかったことは「メインスレッドそのものが止まっている」仮説2と整合する。

### 確定した根本原因
`WatchNowPlayingView.hiddenCrownVolumeControl`（Now Playing ページの不可視 Crown 音量コントロール、`autoFocusesCrown: true`）は、`onAppear` の度に無条件で `wkInterfaceObject.focus()` を呼んでいた（`WatchQueueVolumeView.swift` 内 `SystemVolumeControl.updateWKInterfaceObject`）。`WatchRootView` の paged `TabView` は隣接ページをマウントしたまま保持する設計のため、キュー&音量ページが実際に画面に出ている間も Now Playing 側がオフスクリーンのまま `onAppear` を再発火させ、フロントにないコントロールに対して `focus()` が呼ばれ続けていた。

`sample <pid>` でフリーズ中のプロセスをサンプリングした結果、メインスレッドの100%（初回2331/2331サンプル、再現実験でも4195/4195サンプル）が次の呼び出し連鎖の中にあった:

```
SystemVolumeControl.updateWKInterfaceObject(_:context:)  [WatchQueueVolumeView.swift:68 — focus()]
  → -[WKInterfaceObject _sendValueChanged:forProperty:] → ... → -[PUICSlider becomeFirstResponder]
  → -[UIView(Hierarchy) becomeFirstResponder] → 複数階層の -[UIResponder _setFirstResponder:]
  → @objc _UIHostingView._didChange(toFirstResponder:) → ViewGraphRootValueUpdater.responderNode.getter
  → AG::Graph::update_attribute → AG::Graph::UpdateStack::update()/push_slow(...)
  → （一部サンプルで）AG::Graph::print_cycle(...) → fprintf 経由の書き込みループ
```

現在フロントのインターフェースコントローラーに属していない `WKInterfaceVolumeControl` に対して `focus()` を呼ぶと、WatchKit のレスポンダーチェーンを通じて SwiftUI の AttributeGraph が更新中の自分自身へ再入し、AttributeGraph はこれを依存関係サイクルとして検出・復旧しようとし続ける（`push_slow`/`update()`/`print_cycle` を回り続ける）。この間メインスレッドはランループに制御を返さないため、タッチによるページスワイプも Digital Crown の回転も一切処理されない — ユーザー報告どおりの「両方効かない」完全な引っかかりと一致する。

### リグレッション判定（手動 bisect）
コミット `bfb7705`（Crown をシークから音量操作に変更した回。`SystemVolumeControl` は `hasFocused: Bool` で `focus()` を生涯一度だけ呼ぶ実装）を別ワークツリーでチェックアウトし同じ手順で検証したところ、フリーズは再現せずキューページから正常にスワイプで復帰できた（CPUもアイドルのまま）。次のコミット `7b8f532`（`ViewThatFits` 移行と同時に `hasFocused: Bool` を `refocusTrigger: Int` へ変更し「ページ表示のたびに再フォーカス要求」に変えた回、上記第3ラウンドの追記参照）で同じ手順を実行したところ、CPU 100%張り付き・スワイプ&Crown無反応の完全なフリーズを確認した。**したがって本バグは `7b8f532` で混入したリグレッションであり、直後の `c68ad5d`（音量HUD追加）はこのロジックに触れておらず無関係。**

### 修正
Crown フォーカス要求を「ページが appear したか」ではなく「ページが実際に選択中か」に紐付けた。
- `WatchRootView` が `TabView` の `selectedPage` から `WatchNowPlayingView(isActive: selectedPage == .nowPlaying)` を渡す。
- `WatchNowPlayingView.hiddenCrownVolumeControl` は `autoFocusesCrown: isActive` とし、`crownRefocusTrigger` は `isActive` が `true` に変わった遷移でのみインクリメント（`onAppear` からは削除）。
- 結果、キュー&音量ページが表示されている間は Now Playing の隠しコントロールが常に `autoFocusesCrown: false` となり、`updateWKInterfaceObject` のガードで `focus()` 呼び出し自体が発生しなくなる — AttributeGraph サイクルの引き金を根から断つ。

キューページ自身の `SystemVolumeControl`（`autoFocusesCrown: false` のまま、Crown はリストスクロールに委ねる設計）に変更はない。

### 検証
Apple Watch SE 3 (40mm), watchOS 26.5 シミュレータで、修正前ビルドと同一の再現手順（28曲・実アートワークをシード→ライブラリ→曲→タップ→キューへスワイプ）を実行。
- 修正前: `ps` 確認でCPUが継続的に100%前後、キューページから一切復帰不可（スワイプ・縦スクロールともに無反応）。
- 修正後: 同じ操作でキューページに入った直後もCPUはアイドル（1〜6%）。キュー⇄再生中⇄ライブラリの3ページを複数回往復してすべて正常にスワイプ復帰し、キューリストの縦スクロールも正常に動作した。
- `xcodebuild -scheme UX-Music-Watch -destination 'generic/platform=watchOS Simulator' clean build` → BUILD SUCCEEDED、新規警告なし（既知の2件のみ: `WatchSongListView.swift:130` contextMenu非推奨、`WatchAudioPlayerService.swift:224` Sendable）。
- `xcodebuild -scheme UX-Music-Mobile -destination 'platform=iOS Simulator,name=iPhone 17' test` → 383件成功／1件スキップ（既知の `LANDiscoveryPeerTests.testRealDeviceDiscoversUXSyncMDNSPeer`）で全緑。

### 制約・未検証事項
- **2種目のウォッチサイズでの対話的検証は今回のセッションでは完了できなかった**。シミュレータ操作ツールは新規デバイスへ接続するたびにユーザーの明示許可（「Let Claude use it」）を要求する仕組みで、`Apple Watch SE 3 (40mm)` 以外の全デバイス（Ultra 3 49mm・Series 11 42mm 等）への接続要求が非対話セッション中はタイムアウト/未許可のまま解消できなかった。ただし今回の原因も修正も画面サイズ・Dynamic Type・`ViewThatFits` の候補選択とは無関係で、`TabView` のページ選択状態のみに基づくロジックのため、サイズによって挙動が変わる要素はコード上存在しない。次回、対話セッションで許可が下りた際に他サイズでの目視確認を推奨。
- 仮説1で指摘した `WatchSongRow`/`WatchArtworkThumbnail` の非キャッシュ同期デコードは実在する別件の技術的負債。今回のフリーズの原因ではないためスコープ外としたが、キューが数百曲規模になった際の描画コスト増を避けるため、`WatchNowPlayingView.cachedArtworkImage` 相当のキャッシュ機構を検討する価値はある。
