# サイドカーポーラーによるCPU/メモリ増加バグの調査と修正

## Decision
- 実機報告「サイドカー表示が出ている間、UIハング・メモリ増加・CPU高騰」を調査。当初仮説（ポーラー多重化・present/dismissストーム・毎ティック再フェッチ）はコードを読んで棄却したが、追加証言「Macの再接続操作より前、起動直後から増加が始まる」を受けて、サイドカー画面が常時表示され続ける間の描画コストに焦点を絞った。
- 確定した根本原因は2つ、いずれも「実際には変化していない値の書き込みが不要な再描画を誘発する」パターン：
  1. `AppModel.sidecarPollOnce()`（`App/AppModel.swift`）が2秒毎のポーリング成功時、`sidecarTitle`/`sidecarArtist`/`sidecarAlbum`/`sidecarArtworkId`/`sidecarSongId`/`sidecarDuration`/`sidecarPlaying`を値が変わっていなくても無条件に書き込んでいた。`@Observable`のsetterは値の等値性を見ずに毎回invalidationを発火するため、同じ曲を再生し続けている間も2秒毎にこれらを読む全ビュー（`SidecarArtworkView`、タイトル/アーティストラベル等）が再評価されていた。
  2. `SidecarScreen.swift`の`SidecarSyncedLyricsList`が`TimelineView(.periodic(from: .now, by: 0.2))`（5Hz）の中に`ScrollViewReader`/`ScrollView`/歌詞`ForEach`全体を丸ごと入れていたため、アクティブ行が変わっていなくても5回/秒、歌詞全行の`Text`ツリーを再構築していた。サイドカー表示中は常時これが走り続ける。
- 修正:
  1. `SidecarMetadataSnapshot`（Equatable構造体、`Services/SidecarDirective.swift`）を導入し、ポーラーは新旧スナップショットを比較して差分がある時だけ書き込むように変更。`sidecarPosition`/`sidecarPositionTimestamp`は補間の基準時刻更新のため従来通り毎ティック書き込む。
  2. `SidecarActiveLineUpdatePolicy.shouldUpdate(currentIndex:newIndex:)`を導入し、`SidecarSyncedLyricsList`は`ScrollView`/`ForEach`をTimelineViewの外に出し、`@State private var activeIndex`をTimelineViewのtickから`.task(id: context.date)`経由で「実際にアクティブ行が変わった時だけ」更新するよう再構成。5Hzの補間計算自体は維持しつつ、重い`ForEach`の再構築頻度を大幅に削減。

## Alternatives considered
- ポーラーのTaskキャンセル漏れ・present/dismissループ・毎ティック歌詞再フェッチは実装を読んで棄却（`startSidecarPolling`は既存Taskを確実にcancelしており、`.task(id:)`系はいずれもID変化ゲート済み）。
- `withFailover`のホストプロモーション/リトライも、逐次await・`try?`で握りつぶし・10秒タイムアウトのRemoteLANURLSession設定を確認し、ビジーループ化する経路は無いことを確認（`while !Task.isCancelled`ループのsleepは常に実行される）。

## Constraints / Gotchas
- Swiftの`@Observable`マクロは値の等値性チェックを自動でしない。「頻繁に同じ値を書き込む」プロパティは呼び出し側で明示的に差分ガードしないと、読み手のビューが無条件に再評価され続ける。
- `TimelineView`の`content`クロージャの中に重いサブツリーをまるごと置くと、そのスケジュール周期（今回は0.2秒）でサブツリー全体が再構築される。頻繁なtickが必要なのは「値の計算」だけで、実際に画面へ反映すべき頻度（今回は行が変わる瞬間だけ）とは別物なので、両者を分離する必要がある。

## Decision (2026-08-15 追記: 真の根本原因はオリエンテーション整合性不一致)

- 上記のポーラー/TimelineView修正（`a5213e6`）を適用した後も実機・シミュレータ双方で「サイドカーを一度も出していない状態、Libraryタブに置いただけ」でRSSが分単位で1.5GBまで単調増加し、CPUがほぼ100%に張り付く現象が再現した。`log stream`で`BLSInvalidateFrameSpecifiersAction`（シーンのフレーム/ジオメトリ再計算要求）が毎秒数千件発生していることを確認し、原因をUIKitのシーンジオメトリ管理側に絞り直した。
- 導入コミットは `86eb43d`（サイドカー表示中に画面を横向き固定する機能）。`AppDelegate.swift`が新設され、`UIApplicationDelegateAdaptor`経由で`application(_:supportedInterfaceOrientationsFor:)`を一元管理するようになったが、サイドカー非表示時のデフォルト値が`SidecarOrientationLock.current = .all`だった。
  - `Info.plist`の`UISupportedInterfaceOrientations~iphone`はPortraitUpsideDownを含まない（Portrait / LandscapeLeft / LandscapeRight のみ）が、`.all`はPortraitUpsideDownを含む。デリゲートがInfo.plistの宣言より広いマスクを返すため、アプリ起動直後（サイドカーを一度も出していない状態）からUIKit/BackBoardServicesが「デリゲートの回答」と「Info.plistの宣言」の不一致を解決しようとして`requestGeometryUpdate`相当のフレーム再計算を無限に繰り返し、`BLSInvalidateFrameSpecifiersAction`のストームとRSS単調増加を引き起こしていた。サイドカーの`onAppear`/`onDisappear`は無関係で、デフォルト値の時点で既に壊れていた。
- 修正: `SidecarOrientationLock`にデバイスidiom（iPad/iPhone）に応じた`defaultMask`（iPhoneは`.allButUpsideDown`、iPadは`.all`）を追加し、Info.plistの宣言と常に一致させた。`SidecarOrientationPolicy.mask(sidecarPresented:defaultMask:)`はサイドカー非表示時にこの`defaultMask`をそのまま返す（従来は固定で`.all`を返していた）。`SidecarScreen.applyOrientation`と既存テスト（`SidecarDirectiveTests`）もこのシグネチャ変更に追随。
- 検証: iPhone 17シミュレータでビルド・インストール・起動し、Libraryタブのまま60秒観測。修正前はRSSが単調増加しBLSイベントが多発（過去セッションで1.5GB/分オーダーを確認済み）、修正後はRSSが約265〜300MB台で横ばい・CPU 0.5%・直近60秒のBLSイベントは1件のみとなり、ストームが解消したことを確認した。

## Alternatives considered (追記)
- ポーラー/TimelineViewの差分ガード漏れを再度疑ったが、`AppModel.sidecarPollOnce()`と`SidecarActiveLineUpdatePolicy`は既に`a5213e6`で差分ガード済みであり、かつサイドカー画面自体が一度も表示されていない状態でも再現したため棄却。原因はサイドカーのUI側ではなく、アプリ全体のシーン管理（`AppDelegate`）のデフォルト値にあった。

## Decision (2026-08-15 第3ラウンド追記: サイドカー表示中のみ発生する第3の原因 — TimelineViewの`.now`アンカー再構築ループ)

- 上記2件の修正後も実機で「サイドカー表示中のみ」CPU高騰・メモリ増加が再現するとの報告。今回は実デスクトップなしで再現・特定するため、`UXM_DEBUG_SIDECAR_HOST`/`UXM_DEBUG_SIDECAR_PORT`環境変数フック（`UXMusicMobileApp.swift`、`UXM_DEBUG_YT_VIDEO`と同パターン）と`scripts/sidecar_stub_server.py`（`/v1/remote/state`スタブ、`server/app_remote.go`のJSON形状を模倣）を新設し、iPhone 17シミュレータでサイドカー画面を確実に表示させて計測した。
- **手順**: `python3 scripts/sidecar_stub_server.py --port 8799` を起動 → ビルドしたアプリを`xcrun simctl install`→ `SIMCTL_CHILD_UXM_DEBUG_SIDECAR_HOST=127.0.0.1 SIMCTL_CHILD_UXM_DEBUG_SIDECAR_PORT=8799 xcrun simctl launch <udid> com.uxlabs.uxMusicMobile` → サイドカー画面がフルスクリーンカバーで表示されるのを確認 → `ps -o pid,pcpu,rss` を10秒間隔でサンプリング + `xcrun simctl spawn <udid> log show --last Ns --predicate 'eventMessage contains "BLSInvalidateFrameSpecifiersAction"'` でイベント数計測 + `sample <pid> <N>` でメインスレッドスタックを採取。
- **計測（修正前、フルコンテンツ・オリエンテーション強制ON）**: CPU 99〜100%張り付き、RSSが数十秒で400MB台→1GB超へ単調増加、`BLSInvalidateFrameSpecifiersAction`が20秒間で330,050件（≈16,500件/秒）。`sample`のメインスレッドコールグラフは `CA::Transaction::commit → ... → ViewGraphRootValueUpdater.render → GraphHost.flushTransactions → AG::Subgraph::update → SidecarScreen.body.getter` が支配的で、body評価が絶え間なく繰り返されていた。
- **一次仮説の棄却**: ラウンド2と同じ「オリエンテーション整合性不一致」（`SidecarScreen.applyOrientation`が`.landscape`マスク＋`requestGeometryUpdate`を要求するがシミュレータは物理的にportraitのまま）を疑い、`applyOrientation`を丸ごと無効化（マスク変更なし・ジオメトリ要求なし）して再計測したが、**ストームは変化せず継続**（5秒で133,112件・81,538件）。オリエンテーション機構は今回の原因ではないと判明・棄却。
- **二分探索**（`applyOrientation`無効のまま、`SidecarScreen.body`の内容を一つずつ足し引きして再ビルド・再計測）:
  - bodyを`Text("stub")`のみに置換 → ストーム消失（BLS 1件/5秒、CPU 0.4%）。フルスクリーンカバーの提示機構自体は無罪と確認。
  - `GeometryReader`＋`artworkAndInfo`＋`lyricsPane`＋`progressBar`（クローズボタンなし）→ ストームなし（CPU 1.2%）。
  - 上記に閉じるボタン（`NowPlayingNavIconButton`、`.ultraThinMaterial`・`.opacity(chromeVisible ? 1:0)`・`.animation(value:)`付き）を追加 → **ストーム再現**（5秒で119,497件）。
  - 閉じるボタンから`.ultraThinMaterial`を撤去（不透明色に置換）してもストーム継続（108,449件）→ ブラー素材は無罪。
  - `.animation(value:)`を撤去してもストーム継続（108,449件）→ アニメーションモディファイアも無罪。
  - `Button`ラッパーを撤去し`Image`単体＋`.opacity(chromeVisible ? 1:0)`のみにしてもストーム継続（109,925件）→ インタラクティブ要素も無罪。
  - `.opacity(chromeVisible ? 1:0)`を静的`opacity`に戻す（`chromeVisible`を読まない）と**ストーム消失**（1件/5秒）。ここで「`chromeVisible`を読む兄弟ビューの存在」が必要条件と特定。
  - `GeometryReader`を撤去（静的`VStack`に置換）してもストーム継続（`progressBar`＋`chromeVisible`読み取りビューのみで再現、5秒で107,352件）→ `GeometryReader`も無罪。
  - `artworkAndInfo`/`lyricsPane`をプレースホルダ`Text`に置換してもストーム継続（85,386件）→ ネットワーク依存サブビュー群も無罪。最終的に「背景＋スクリム＋プレースホルダ＋`progressBar`＋`chromeVisible`を読む兄弟ビュー」の最小構成でも再現することを確認。
- **真因**: `progressBar`は`TimelineView(.periodic(from: .now, by: 0.25))`で、tickごとに`.onChange(of: context.date) { chromeNow = newDate }`という**親ビュー（`SidecarScreen`）の`@State`を書き込む**。`chromeNow`は`SidecarScreen`自身の計算プロパティ`chromeVisible`が参照しており、それを閉じるボタンの`.opacity(chromeVisible ? 1:0)`が読んでいる。したがって`chromeNow`が変わるたびに`SidecarScreen.body`全体が再評価され、`progressBar`（＝新しい`TimelineView`インスタンス）が**毎回作り直される**。ここで`from: .now`は**再構築のたびにその時点の`Date()`で再評価される**ため、新しいスケジュールは常に「たった今」を起点とし、最初のtickがほぼ即座に発火する。これが`chromeNow`を再度書き込み→再び`body`再評価→また新しい`TimelineView`が`.now`で再構築…という**アンカーレス・フィードバックループ**を形成し、メインスレッドが可能な限り高速にこのサイクルを回し続けてCPU100%・BLSストーム・RSS単調増加を引き起こしていた。`SidecarSyncedLyricsList`内のもう一つの`TimelineView(.periodic(from: .now, by: 0.2))`も同型パターン（tickが`activeIndex`という自ビューが読む`@State`を書く）だが、`SidecarActiveLineUpdatePolicy.shouldUpdate`が実際に行が変わった時だけ書き込むようゲートしているため、無条件ループにはならず今回は顕在化していなかった（同じ原理の潜在バグとして同時に修正）。
- **修正**（`UX-Music-Mobile/UX-Music-Mobile/Views/SidecarScreen.swift`）: 両方の`TimelineView`のアンカーを`.now`（式評価のたびに変わる）から、ビュー初回構築時に一度だけ固定される`@State`（`progressScheduleAnchor`／`lyricsScheduleAnchor`、いずれも`= Date()`で初期化）に変更。ビューが何度再構築されても同じアンカーを渡すため、スケジュールが安定し毎tickごとの即時再発火が起きなくなる。ロジック自体（`SidecarProgressInterpolation`・`SidecarChromeVisibilityPolicy`・`SidecarActiveLineUpdatePolicy`）は無変更。SwiftUIのビュー構造体の配線に起因する問題のため、TDD対象の純粋関数ロジック変更はなし（既存の`SidecarDirectiveTests`は全て green のまま）。
- **検証（修正後、フルコンテンツ・オリエンテーション強制ON、同一計測手順で3分間）**: RSSは285〜295MB台で横ばい（増加傾向なし）、CPUは0.8〜1.8%で安定、直近60秒の`BLSInvalidateFrameSpecifiersAction`は1件（ベースライン相当）。修正前の単一5〜20秒ウィンドウで74,699〜330,050件だったのに対し、3分間ずっと1件のみ。スクリーンショットで進捗バーの伸縮・時間ラベル/閉じるボタンのアイドル時フェードアウト（`SidecarChromeVisibilityPolicy`）も正常動作を確認。
- **デバッグハーネスの扱い**: `UXM_DEBUG_SIDECAR_HOST`/`UXM_DEBUG_SIDECAR_PORT`フックは今回で3回目の必要になったため、`#if DEBUG`で囲わず（既存の`UXM_DEBUG_YT_VIDEO`/`UXM_DEBUG_LYRICS_SONG`と同じ「環境変数未設定時は無害」方式）恒久的に残すことにした。`scripts/sidecar_stub_server.py`はリポジトリに追加（`server/app_remote.go`のJSON形状を手動で追従させる必要がある点は既知のメンテナンスコスト）。

## Alternatives considered (第3ラウンド追記)
- オリエンテーション整合性不一致（ラウンド2と同型の再発）を最有力候補として最初に検証したが、`applyOrientation`を完全に無効化してもストームが変化しなかったため実測で棄却。
- `.ultraThinMaterial`によるライブブラーの継続的再サンプリング、`.animation(value:)`によるCore Animation継続コミット、`Button`のジェスチャ認識機構、`GeometryReader`によるウィンドウジオメトリ問い合わせを順に疑ったが、いずれも単体除去でストームが消えなかったため実測で棄却。真因は`TimelineView(.periodic(from: .now, ...))`が親`@State`書き込みと組み合わさった際のアンカー再構築ループだった。
