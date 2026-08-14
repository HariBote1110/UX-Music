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
