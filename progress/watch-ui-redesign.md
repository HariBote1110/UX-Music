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

## 追記 (2026-08-09 第5ラウンド): 行アートワークのデコードキャッシュ実装 + フラット曲リストへのアルバム連結線UI試験導入

第4ラウンドで技術的負債として残した「`WatchSongRow`/`WatchArtworkThumbnail` の非キャッシュ同期デコード」の解消と、デスクトップ/iOS の看板 UI（連続する同一アルバム行の連結線表現）の Watch フラット曲リストへの試験導入を、同じ行コンポーネントを書き換える一続きの作業として実施。

### アートワークデコードキャッシュ

- **設計**: `Core/ArtworkMemoryCache.swift` に、値の型に依存しない汎用 LRU キャッシュ `ArtworkMemoryCache<Value>` を新設。容量超過時は最も長く未参照のキーから追い出す。スレッド安全性は `actor` ではなく `NSLock` — SwiftUI `body` からの同期読み出しと、バックグラウンドデコード後の書き込みの両方を `await` なしで行える必要があったため。
- **`NSCache` を採用しなかった理由**: `NSCache` の追い出しはシステムの不透明なコスト指標に依存し決定的でない。「容量/追い出しポリシーはテスト可能な形にする」という要件を満たせないため、追い出し順序を明示的に検証できる自前 LRU にした。テストは `ArtworkMemoryCacheTests.swift` に8件（挿入/取得・追い出し・参照によるリフレッシュ・上書き・容量1のエッジケースなど）、`Value` は `UIImage` ではなく `String` を使い、デコード処理と完全に分離してポリシーだけを検証している。
- **Watch 側の統合**: `WatchSongListView.swift` 内に `WatchArtworkThumbnail`（`ArtworkMemoryCache<UIImage>` を包む private な `WatchArtworkCache.shared`、容量80）。`body` 内の同期 `Data(contentsOf:)` + `UIImage(data:)` を廃止し、`.task(id: meta?.id)` から呼ぶ非同期パスに置き換えた。`.task(id:)` は `meta?.id` が変化したときだけ再実行される（前回投稿で問題視した「無関係な `@Published` の変化でも body 再評価のたびに全行が再デコードされる」という経路自体を断つ）。
- **デコードは ImageIO のサムネイル API（`CGImageSourceCreateThumbnailAtIndex`）を `Task.detached(priority: .utility)` の中で実行**。`UIImage(data:)` でフルサイズ（iPhone 転送時点で長辺約400px、`WatchTransferBridge.writeDownscaledArtwork` 参照）を一度デコードしてから縮小するのではなく、ImageIO にターゲットサイズ（96px）を渡してフルサイズのビットマップを一度も確保させない。1エントリあたり概算96×96×4byte≒36KBで、容量80でも合計約2.9MBに収まる。
- **`sample` による検証**（後述の実機データ投入時に実施）: `CGImageSourceCreateWithURL`/`CGImageSourceCreateThumbnailAtIndex`/`IIO_Reader_AppleJPEG` 系のフレームはすべて `com.apple.root.utility-qos` の背景スレッド配下にのみ出現し、メインスレッドの呼び出し木（6秒サンプリング、スクロール操作を継続しながら採取）には一件も現れなかった。メインスレッド側で `WatchArtworkThumbnail.resolvedImage` に到達しているのは `artworkFileURLIfPresent`（`lstat` 呼び出し1回のみ）と `Task.detached` の生成コストだけで、実デコードは確実にオフメインで走っている。

### アルバム連結線 UI の Watch 移植

- **共有した部分**: 実行検出（run 検出）ロジックそのもの。`Core/AlbumGroupPosition.swift` の `AlbumGrouping.positions(for songs: [Song])` は `Song` 依存部分を `#if os(iOS)` で括り、実体は新設の `AlbumGrouping.positions(forAlbumKeys albumKeys: [String])`（`[String]` を受け取るだけの純粋関数）へ委譲する形に分割。これにより同じ run 検出ロジックが Watch ターゲットのビルドにも参加できる（`Song` 型自体は Watch ターゲットに存在しないため、そのままでは共有できなかった）。`AlbumGroupConnector`（行内の線ジオメトリ、`rowHeight`/`artworkSize` でパラメータ化済み）は変更なしでそのまま Watch 側から呼べた。
- **Watch 側で再定義した部分**: 曲一覧の「アルバムキー」の取得元。iOS は `Song.groupingAlbumTitle`（トリム済み・空なら "Unknown Album"）だが、Watch は実体を `WatchTransferMeta` で持つため `displayAlbum`（空なら "Unknown Album"、`WatchAlbumGrouping.albums(from:)` と同じキー）を使う。両者とも「同じ意味のアルバムキー文字列」を `positions(forAlbumKeys:)` に渡すだけなので、`Song`/`WatchTransferMeta` 側の差異を吸収する専用コードは不要だった。
- **フラットリストをアルバム順に並べ替える必要があった**: 今回導入前は `library.songs`（転送順）をそのまま表示しており、連続する行が同じアルバムになることはほぼなく、連結線機能が事実上不可視だった。`Core/WatchPlaybackLogic.swift` の `WatchAlbumGrouping` に `songsSortedByAlbum(_:)` を追加 — 既存の `albums(from:)`（アルバムキーでバケット化・アルバム名昇順・バケット内はトラック到着順を保持）をそのままフラット化するだけの実装。iOS のデフォルト表示順（`Song.libraryFlatDisplayOrderAscending`: アルバム→ディスク/トラック番号）の精神を踏襲しつつ、`WatchTransferMeta` が持たないディスク/トラック番号の代わりに到着順（＝送信元 iPhone 側のトラック順、`WatchAlbumGroup` のドキュメント参照）を使う。
- **Watch 専用メトリクス**: iOS の `SongRowMetrics`（アートワーク48pt・行高64pt・横インセット16pt、画面幅約390pt基準）をそのまま流用せず、`WatchSongListView.swift` に `WatchSongRowMetrics`（アートワーク28pt・行高46pt・横インセット8pt）を新設。アートワークサイズは既存行が使っていた28ptをそのまま維持した — 28〜32ptの推奨レンジ内に収まっており、かつ連結線を使わない側（アルバム詳細・キュー&音量ページ）の見た目を一切変えずに済むため。行高・横インセットは連結線を使う側（フラット「曲」リスト）だけに `WatchLibraryListRowStyle`／固定 `.frame(height:)` として適用し、opt-in しないリストは元の可変高・システム標準余白のまま。
- **連結線は `nil` デフォルトで opt-in**: iOS の `SongRowView.albumGroupPosition` と同じ設計を `WatchSongRow.albumGroupPosition` にも踏襲。アルバム詳細リストとキュー&音量ページは呼び出し側で一切パラメータを渡さないため、常に `nil`（連結線なし・常時アートワーク表示・可変行高）のまま — 見た目・挙動とも今回のリファクタ前と同一であることをシミュレータで確認済み。

### 見た目の検証（シミュレータへの実データ投入 → 削除）

`Apple Watch Series 11 (46mm)` watchOS 26.5 シミュレータの `Library/Application Support`（`library.json`／`Audio/`／`Artwork/`）に、Pillow で生成した実 JPEG アートワーク付きの28曲（複数トラックのアルバム5件＋単曲アルバム8件）を一時的に直接書き込んで検証した（アプリのソース改変は一切なし。`git diff` は投入前後で完全に空）。

- 連結線は行境界をまたいで途切れず連続しており（2トラック・4トラック・6トラックの各runでズーム画像を確認）、runの最終行にのみ `└` エルボーが出ること、先頭行はアートワーク＋下端までの線分（次行への継ぎ目）を出すこと、単曲アルバムはアートワークのみで線が一切出ないことをすべて目視確認した。
- アルバム詳細リスト・キュー&音量ページは、複数トラックの run を含む状態でもすべての行にアートワークが表示され、連結線・行高固定のいずれも適用されていないことを確認（連結線導入前の見た目のまま）。
- 検証後は `simctl uninstall` でアプリごと削除（Application Support 配下の投入データも道連れに消滅）。リポジトリ側は一切変更していないため `git status`/`git diff` は最初から最後まで空のまま。

### 意外だった点・ハマった点

- **`.listRowSeparator(_:edges:)` は watchOS では使えない**（コンパイルエラー: `'listRowSeparator(_:edges:)' is unavailable in watchOS`）。iOS の `LibraryListRowStyle` をそのまま真似ようとして最初にここで躓いた。watchOS の `List` はデフォルトで行間にカード風の余白を入れる設計で、そもそも「セパレータ線」の概念がない。代わりに `List` 自体へ `.listStyle(.plain)` を指定することでカード風の余白そのものを消し、行を隙間なく積む狙いを達成した。
- **`View` に生える `static func`/`static let` はメインアクター分離を暗黙に継承する**。`WatchArtworkThumbnail`（`View` 準拠）の `static func decodeThumbnail` を `Task.detached` の中から呼んだところ、「メインアクター隔離のプロパティ/関数をアクター外から呼んでいる」という警告（Swift 6 モードではエラー）が出た。`nonisolated` を明示的に付けることで解消 — `body` がメインアクター前提であることの副作用として、同じ型に生える static メンバーまで暗黙に隔離される点は事前に想定していなかった。

## 追記 (2026-08-09 第6ラウンド): 実機報告「連結線が途切れる」「曲一覧が死ぬほど重い」の調査と修正

第5ラウンドでシミュレータのズーム画像を目視して「連結線は途切れず連続」と報告したが、ユーザーが実機（Apple Watch 実機）で試したところ両方とも実機で確認された。「検証済み」の前提を疑い、シミュレータ上で再調査した。

### 1. 連結線の途切れ — 原因確定・ピクセルレベルで実証

**仮説**: watchOS の `List` は `.listStyle(.plain)` + 各行 `.listRowInsets(top: 0, bottom: 0)` を設定しても、行間隔を完全にゼロにはできないのではないか。

**検証方法**: Apple Watch Series 11 (46mm) watchOS 26.5 シミュレータに28曲（複数トラックのアルバム5件＋単曲8件、実JPEGアートワーク付き）を投入し、`xcrun simctl io <udid> screenshot` で**フル解像度**（416×496px、2倍スケール）のスクリーンショットを取得。第5ラウンドで使った「ズーム画像を目視」ではなく、Python（Pillow）で連結線の色（`Color.secondary.opacity(0.35)` を黒背景に合成した暗いグレー、おおよそ RGB(49,49,51)）を検出する列を特定し、その列を1ピクセルずつ縦にスキャンして「連結線が途切れずに連続しているか」を機械的に判定するスクリプト（`check_connector_continuity.py`、非コミット・スクラッチパッドに保存）を書いた。

**結果（修正前 = `List` 版）**: 連結線の列（x=47px）を縦にスキャンしたところ、行の境界ごとに **正確に30px（=15pt @2x スケール）の空白帯** が繰り返し出現し、連結線が3回に分断されていることを確認した:
```
ON  y=208..225 (18px)   -- 1行目の "first" 線分（アートワーク下端から行末まで）
GAP y=226..255 (30px)   -- ← ここが途切れ。15pt相当
ON  y=256..347 (92px)   -- 2行目の "middle" 線分（行の上端から下端まで、46pt分）
GAP y=348..377 (30px)   -- ← 同じく途切れ
ON  y=378..419 (42px)   -- 3行目の "last" 線分
```
各行内の線分自体は `WatchSongRowMetrics.rowHeight`（46pt）どおり正確に描画されていた（`AlbumGroupConnector` のジオメトリ自体は正しい）。途切れているのは行と行の**間**であり、`.listRowInsets` で top/bottom を 0 にしても watchOS の `List` はここに約15ptの追加余白を入れてくる（`.listStyle(.plain)` はカード風の背景/角丸は消すが、この行間隔は消せない）。iOS の `List` の `.plain` スタイルとは異なる挙動で、これが watchOS 固有の制約だと確定した。

**修正**: `WatchSongListView.songList` を `List` から iOS の `RemoteLibraryScreen.remoteSongsList`（`SongRowView` を使う既存の確立済みパターン）と同じ `ScrollView` + `LazyVStack(spacing: 0)` に置き換えた。`spacing: 0` で行間隔を直接ゼロに指定できるため、watchOS `List` の不透明な既定値に頼らずに済む。長押しコンテキストメニュー（削除）は `WatchSongRow.body` 内の `Button` にそのまま残しており、`swipeActions` は導入していない（ページ横スワイプとの競合を避ける既存方針を維持）。

**修正後の検証**: 同じスクリプトで、Apple Watch Series 11 (46mm) と Apple Watch SE 3 (40mm) の両方のシミュレータで確認：
- 46mm・28曲: 連結線は `y=198`〜`y=446` まで**途切れなく1本**（249px）。
- 40mm・28曲: 連結線は `y=169`〜`y=393` まで**途切れなく1本**（225px）。
- 46mm・320曲（大規模ライブラリでも再確認）: `y=198`〜`y=489` まで**途切れなく1本**（292px）。

いずれも `GAP` は0件。修正前は同じ計測で必ず複数の `GAP`（15pt相当）が出ていたことと対比すると、原因と修正の対応が明確に取れている。

**なぜ第5ラウンドの目視検証はこれを見逃したか**: ズーム画像を目視で確認した際、「線が繋がって見えるか」という定性的な印象だけで判断しており、15pt程度の途切れは行の高さ（46pt）に対して約33%と大きいにもかかわらず、スクリーンショットの縮小・圧縮や画面キャプチャツールの結合方法によっては視覚的に「まあ繋がっている」ように見えてしまっていた可能性が高い。また、シミュレータでの目視確認はホストMacの高解像度ディスプレイ経由で見ており、実機の物理的に小さい画面・pixel densityでは同じ15ptの途切れがより顕著に見える（あるいは目視でのピクセル単位の判定自体が難しい）。今回の教訓として、**「連続しているべき線」の検証は目視ではなくフル解像度スクリーンショットのピクセル値を機械的に検査する**方式に切り替えた。

### 2. 「曲一覧に入るのが死ぬほど重い」— シミュレータでは再現せず、原因候補を検証した上で棄却/確定

**検証方法**: `sample <pid>` によるCPUプロファイリングと、`print` + `fflush(stdout)` による関数呼び出し回数の実測（一時的な計測コード、コミット前に `git checkout` で完全に削除済み）を、28曲・320曲（40アルバム×8トラック）の両方のシード済みライブラリで実施。

**候補1: 行アートワークのデコード同時実行数の爆発（"decode storm"）** — **棄却**。`sample` でメインスレッド以外のスレッドを確認したところ、`__workq_kernreturn` で待機しているだけのアイドルなワーカースレッドが大半で、実際に画面遷移直後に走った `Task.detached` の呼び出し回数を `print` でカウントしたところ、28曲・320曲いずれの場合も**1〜2件**（画面に見えている行数と一致）だった。理由は、watchOS の `List` は内部的に `UICollectionView` で実装されており（`sample` の呼び出し木に `UICollectionViewListCoordinatorBase` が確認できた）、そもそも画面外の行は遅延生成されていたため。`ScrollView` + `LazyVStack` へ切り替えた後も同様に1〜2件のままで、この点は変化なし（`LazyVStack` も遅延描画のため）。

**候補2: `songList(_:)` が body 評価のたびにソート/グルーピングを再計算していた** — **実在すると確定、かつ想定より頻繁だった**。`print` 計測により、`songsSortedByAlbum`/`positions(forAlbumKeys:)` を呼ぶ `songList(_:)` が、**「曲」行を実際にタップする前、ライブラリ画面が表示された時点で既に2回呼ばれている**ことを確認した（`NavigationLink(destination:label:)` はラベル行が画面に出た時点で `destination` を先行構築するため — 遅延評価されるのは `NavigationLink(value:) + .navigationDestination(for:)` の場合のみで、今回使っている旧来の closure ベースの初期化子はそうではない）。320曲でもこの2回の呼び出しはアプリ起動後0.1秒程度で完了しており、単体としては軽い処理だが、ライブラリ画面が再描画されるたびに（無関係な理由も含めて）無駄な再計算が発生する構造だった。`WatchLocalLibrary` に `flatOrder`（`WatchFlatSongOrder`、新設の純粋関数）を追加し、`songs` が実際に変化した瞬間（`addSong`/`removeSong`/`loadFromDisk`）にのみ1回計算してキャッシュする方式に変更した。

**結論**: シミュレータ上（28曲・320曲いずれも、Mac の高速なCPU上で実行）では、修正前後で `sample` によるメインスレッドCPU使用量に有意な差は見られず（修正前 177ms/6秒・修正後 234ms/6秒、いずれも計測誤差の範囲）、「死ぬほど重い」と体感できるレベルの遅延は**シミュレータでは一度も再現できなかった**。これは実機のCPU性能がシミュレータ（Macのホストで実行）よりも大幅に低いためだと考えられ、今回の調査で確定的な原因を実機計測なしで特定することはできなかった。ただし、候補2で確定した「無駄な重複計算」は実在するバグであり、実機のような非力なCPUでは相対的な影響が大きくなる可能性が高いため修正した。候補1（デコード同時実行数）は明確な証拠とともに棄却しており、以後の調査でこの仮説を再検証する必要はない。

### 制約・未検証事項

- **実機での性能計測は今回のセッションでは実施できなかった**（実機への接続手段がない非対話セッションのため）。シミュレータでは「死ぬほど重い」を再現できなかったため、修正が実機での体感速度をどの程度改善するかは次回、実機での計測を推奨する。
- 2種類の画面サイズ（Apple Watch Series 11 46mm・Apple Watch SE 3 40mm）でのシミュレータ検証は完了。それ以外のサイズ（Ultra 3 49mm・Series 11 42mm・SE 3 44mm）は未検証。
- `WatchLibraryListRowStyle`（`List` 専用の行間隔調整用 `ViewModifier`）は `songList` が `List` を使わなくなったことで用途がなくなったため削除した。他の箇所（アルバム詳細・アルバム一覧・キュー&音量ページ）は元々これを使っておらず影響なし。
