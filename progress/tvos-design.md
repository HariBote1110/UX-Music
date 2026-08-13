# Apple TV「シネマティック」デザイン言語（案B）採用

## Decision

ユーザーが「UX Musicと繋がるだけで精神的な繋がりを一切感じないUI」として現行の素のtvOS UIを却下し、
デスクトップ版のデザイントークンを継承した「案B（シネマティック）」を承認。`UX-Music-TV/TVDesignTokens.swift`
に共有トークン・共有ビュー部品として実装し、Now Playing・Browse・Pairing/Discoveryの3画面へ横展開した。

- **パレット**: チャコール `#161618`（ベース）/ `#1c1c1e`（サーフェス）/ `#2c2c2e`（挙上サーフェス）。
  文字色は白 / `#a1a1aa`（セカンダリ）/ `#71717a`（ターシャリ）。
  デスクトップのプログレスバー・EQ配色と同じシグネチャーグラデーション ピンク `#ff5d77` → ブルー `#3b82f6` を、
  進捗バー・フォーカスの縁取り・現在再生中歌詞のアクセントバーに使用。
- **背景**: `TVCinematicBackground` が全画面チャコールの上に、静的な `RadialGradient` 2つ（左上ピンク・右下ブルー）を
  重ねる「ライトプール」を描画。ライブblurではなく固定半径のグラデーションなので tvOS でも滑らかに動く。
  `breathing: true`（アンビエント時）でオパシティのみをゆっくりアニメーションさせ、ぼかし半径のアニメーションは避けた
  （パフォーマンス制約どおり）。
- **Now Playing**: 左に丸角カード化したアートワーク（角丸8pt・ピンク寄りのシャドウ）。右にタイトル（`.medium`太さ）・
  アーティスト・3行フォーカス歌詞ブロック（前の行=ミュート小、現在行=白・大・左端4ptピンクアクセントバー、
  次の行=ミュート）。歌詞なしの曲はこれまでどおりアートワーク中心レイアウトへフォールバック。下部にピンク→ブルー
  グラデーション塗りの薄い（4pt）プログレスストリップ。トランスポートボタンは既存 `TVTransportButtonStyle`
  （フォーカスでスケール/明度変化）を維持し、新背景に合わせて微調整のみ。
- **Browse**: 同じチャコール＋ライトプール（`intensity: 0.6` でNow Playingより控えめ）。棚カードは
  `TVCinematicCardStyle`（新規 `ButtonStyle`）を適用し、`.buttonStyle(.card)` の標準グレーカプセルの代わりに
  `@Environment(\.isFocused)` を見てフォーカス時のみピンク→ブルーの角丸ボーダー（`strokeBorder`）＋ソフトなピンク
  シャドウを描く。tvOSのSwiftUIには `.card` スタイルの内部フォーカス演出（白ハロー）を直接差し替えるAPIがなく、
  代わりに独自 `ButtonStyle` に丸ごと置き換える方式にした（`TVTransportButtonStyle` と同じアプローチ）。
- **アンビエントモード**: 既存 `TVAmbientStateMachine`（30秒無操作＋再生中のみ、TDD済み）のセマンティクスと
  二段階Menu終了フローはそのまま。表現面のみ、`TVCinematicBackground(breathing: true)` でライトプールがゆっくり
  明滅し、アートワークウォッシュ（後述）の不透明度をさらに下げてアートワークを後退させる。
- **Pairing/Discovery**: `TVRootView` に `TVCinematicBackground(intensity: 0.5)` を適用し、6桁ペアリングコードに
  シグネチャーグラデーションの文字色を付与。構造・ロジックは無変更。

## アートワーク色抽出の判断（v1）

真の「アートワークの支配色を抽出してグラデーションに混ぜる」処理は実装せず、v1では次の簡易版を採用した:

- `TVNowPlayingAmbientBackground` が、現在のアートワークを強くぼかし（blur 70〜90pt）、低い不透明度
  （0.18〜0.3）・`blendMode(.plusLighter)` で `TVCinematicBackground` の上に重ねるだけ。
- 理由: tvOS 上でのピクセルサンプリング（`CIAreaAverage` 等）はメインスレッドを塞ぎやすく、フォーカス操作の
  レイテンシに直結する 10-foot UI では体感の滑らかさを最優先すべきと判断。ブリーフ側も「抽出が重ければ
  シグネチャーカラーのみでv1は許容」と明記されていたため、それを採用した。
- 将来 Phase で本格的な色抽出（バックグラウンドタスクでのダウンサンプリング＋出現色の量子化）をやる場合は、
  結果をアートワークIDごとにキャッシュしてから `TVCinematicBackground` へ色を渡す形にする想定。

## Alternatives considered

- **`.buttonStyle(.card)` を維持しつつ overlay だけ足す**: tvOS の `.card` スタイルはフォーカス時に自前で白い
  ハローを描画するため、overlay を足しても両方が重なって視覚的にノイズになった。全面差し替え
  （`TVCinematicCardStyle`）の方がデザイン意図に忠実。
- **ライブGaussianBlurをアンビエント/背景に多用**: 案として検討したが、ブリーフの「静的radialグラデーション＋
  opacity/positionのゆっくりしたアニメーションを優先」という制約と、tvOS実機でのblurコストを踏まえ、既存の
  `TVNowPlayingAmbientBackground` のblurは維持しつつ主役をライトプールに譲る形（低opacity化）に留めた。
- **アートワーク色のリアルタイム抽出**: 上記のとおりv1では見送り。

## Constraints / Gotchas

- 新規Swiftファイル（`TVDesignTokens.swift`）を追加した際は Xcode プロジェクトファイル
  （`UX-Music-Mobile.xcodeproj/project.pbxproj`）に `PBXBuildFile` / `PBXFileReference` / グループ子要素 /
  `Sources` ビルドフェーズの4箇所を手動で追加しないとビルドに含まれない（Xcode GUIを使わずファイル追加した場合の
  既知の落とし穴）。
- `MusicPlayerService` の再生状態プロパティ（`currentSong`/`isPlaying`/`positionSeconds`/`durationSeconds`）は
  すべて `private(set)` のため、プレビュー用スタブは型の外から差し込めない。`#if DEBUG` ブロックで
  `configureForPreview(song:isPlaying:positionSeconds:durationSeconds:)` を `MusicPlayerService` 本体に追加し、
  DEBUGビルドのみ露出させた（Release/実運用パスには一切影響しない）。
- `UXMusicTVApp` は `#if DEBUG` で `ProcessInfo.processInfo.environment["UXTV_PREVIEW"]` を見て
  `TVNowPlayingPreviewHarness` / `TVBrowsePreviewHarness`（いずれも各ビューファイル内 `#if DEBUG` ブロックに実装）
  に分岐する。起動方法:
  ```
  SIMCTL_CHILD_UXTV_PREVIEW=nowplaying xcrun simctl launch --terminate-running-process "Apple TV" com.uxlabs.uxMusicMobile.tv
  SIMCTL_CHILD_UXTV_PREVIEW=browse xcrun simctl launch --terminate-running-process "Apple TV" com.uxlabs.uxMusicMobile.tv
  ```
  ペアリング・LAN接続なしでスクリーンショット検証できる。プレビューハーネスは実在しないホスト
  （`http://198.51.100.1:9999`）を指す `RemoteAPIClient` を使うため、アートワーク画像取得は失敗して
  プレースホルダ（音符アイコン）表示になる——これは想定内（"生成済みプレースホルダー画像"の簡易版）。
- 検証スクリーンショット: `/tmp/claude-501/tvdesign_nowplaying.png`,
  `/tmp/claude-501/tvdesign_browse.png`（38%進捗・3行フォーカス歌詞・フォーカスカードのグラデーション縁取りを確認済み）。

## 追記: アルバム/プレイリスト詳細画面の追加とBrowse実機フィードバック対応

実機（本物のApple TV）でのユーザー確認で3点の指摘があり、対応した。

### Decision（アルバムタップ即再生の廃止 → 詳細画面）

- 「アルバムカードをタップすると即再生される」挙動をユーザーが「意図しない」と報告。
  `TVBrowseView`のアルバム/プレイリストタップは、即再生ではなく`TVLibraryDetailView`
  （新規 `TVLibraryDetailView.swift`）を開くように変更した。
- アルバム・プレイリストで別々のビューを作らず、`TVLibraryDetailContent`という中間データ型
  （`title`/`artist`/`artworkId?`/`songs`）を介して**1つの汎用詳細ビュー**で両方をまかなう
  DRY設計にした。`.album(_:)`/`.playlist(_:allSongs:)`のstaticファクトリで変換する
  （プレイリストは`artworkId`が無いため`nil`→汎用アイコンにフォールバック）。
  プレイリストの曲順解決は既存の`TVPlaylistQueueBuilder.songs(for:allSongs:)`をそのまま
  再利用——重複実装しない。
- 詳細画面の構成: 左に大きめ（320×320）アートワーク＋ピンク寄りシャドウのグロー、右にタイトル・
  アーティスト・「再生」ボタン（`content.songs.first`から再生）。下にフォーカス可能なトラック
  リスト（トラック番号・タイトル・アーティスト・`m:ss`長さ）。各行タップで「そのトラックから
  再生、残りはキュー」——既存の`TVPlaybackController.play(_:queue:)`の再生規則をそのまま使う。
- `TVBrowseView`側は`presentedDetail: TVLibraryDetailContent?`を`.fullScreenCover(item:)`で
  提示。`onPlay`クロージャは`presentedDetail = nil`してから`playbackController.play`と
  `nowPlayingPresented = true`を呼ぶ——詳細画面を閉じてからNow Playingへ、の順序をここで保証。

### Decision（Browse画面のポリッシュ）

- **フォーカスカードのラベルはみ出し**: `TVAlbumCard`/`TVPlaylistCard`のタイトル/アーティスト
  行に`.frame(width: 220, alignment: .leading)` + `.truncationMode(.tail)`を個別に付与し、
  VStack全体にも`.clipped()`を追加。ただし最初の修正だけでは**カードの角丸コーナーぎりぎりに
  文字が接し、フォーカス時のスケールで先頭1文字がコーナーの丸みに食われる**症状が
  シミュレータのスクリーンショットで再現した（"UX Music Demo"の"U"が欠ける）。
  各テキストに`.padding(.horizontal, 4)`を追加してから`.frame(width: 220)`することで解消——
  paddingしてからframeで幅確定、の順序がポイント（逆順だとpaddingがframe外にはみ出る）。
- **上部見出しが弱い**: システムの`navigationTitle`はtvOS上で中央寄り・ミュートグレーで表示され
  「弱い」という指摘どおりだった。`navigationTitle("")`で空にし、代わりに棚と同じ
  `VStack(alignment: .leading)`内に`TVBrowseHeader`（白・`.medium`・40pt、左揃え）を追加。
  オーバーサイズのヒーローにはせず「控えめだが存在感のある」見出しに留めた
  （ブリーフの「大袈裟にしない」指示どおり）。
- プレビューハーネス`TVBrowsePreviewHarness`も実装と同じ構成（`TVBrowseHeader`追加・
  `navigationTitle("")`）に揃えないと、スクリーンショット検証が実装とズレる
  ——これは一度ズレて気づいた（`UXTV_PREVIEW=browse`のスクショに古い中央グレー見出しが
  残っていた）。プレビューハーネスは常に実装側の変更と同時に更新すること。

### 検証

- `UXTV_PREVIEW=albumdetail`を追加（`TVLibraryDetailPreviewHarness`、6曲・長いタイトルの
  トラックでスタブ）。スクリーンショット: `/tmp/claude-501/tvdesign_albumdetail.png`,
  `/tmp/claude-501/tvdesign_browse2.png`（いずれもラベルがカード内に収まり、見出しが
  左揃え・白になっていることを確認済み）。

## 追記: Now Playingが「初期画面のまま」になる再生退行の原因と修正

実機報告「再生画面に何も起こらない。飛ぶだけで初期の画面が表示される」を調査した結果、
上記のアルバム詳細画面導入（コミット7ecbbd5）が原因だった。

### 原因

`TVBrowseView`が独立した3つの`.fullScreenCover`修飾子（Now Playing用の`isPresented:`、
詳細画面用の`item:`、中継バナー用の`isPresented:`）を同じビューに付けていた。詳細画面から
トラックを選ぶと、`onPlay`クロージャが`presentedDetail = nil`（詳細カバーを閉じる）→
非同期`Task`で`playbackController.play`完了後に`nowPlayingPresented = true`
（Now Playingカバーを開く）という順で状態を変えていたが、**この2つは別々の
`.fullScreenCover`修飾子**であり、同じ提示元ビューからの「閉じる」と「開く」がtvOS上で
競合する。詳細カバーの dismiss アニメーションが終わる前に Now Playing の present が走ると、
2つ目の present が黙って失敗し、ユーザーは（dismiss だけが完遂した）ブラウズ画面か、
空のまま残った Now Playing 相当の画面に取り残される——調査時に立てた3つの仮説のうち
「②プレゼンテーションの積み重ね（cover-on-cover はトップの提示元から出す必要がある）」
が実際の原因だった（①のインスタンス重複、③のObservationトラップはどちらも実装済みの
既存パターンを踏襲していただけで問題なし——`MusicPlayerService`は`TVPairingView`で
1つだけ生成され、`TVBrowseView`/`TVNowPlayingView`両方に同一インスタンスが渡っている）。

### 修正

`TVBrowseView`の3つの`@State`（`nowPlayingPresented`/`relayPresented`/`presentedDetail`）を
`TVBrowsePresentation`という1つの`Identifiable & Equatable`列挙型（`.nowPlaying` /
`.detail(TVLibraryDetailContent)` / `.relay`）に統合し、`.fullScreenCover(item:)`
1本に一本化した。詳細画面のトラック選択は`presentedDetail = nil`を経由せず、
`presentation`を`.detail`から`.nowPlaying`へ直接切り替える——同一の提示コンテキストでの
アイテム変更になるため、SwiftUIが確実にカバーの入れ替えを処理する。

### 検証

`UXTV_PREVIEW=detailplay`を追加（`TVDetailPlayPreviewHarness`、`UXMusicTVApp.swift`）。
実プロダクションと同じ`TVBrowsePresentation`を使い、詳細画面を表示した0.4秒後に
（トラック行タップ相当の）`onPlay`クロージャをプログラム的に発火、`MusicPlayerService`を
`configureForPreview`（オーディオエンジン非使用・無音）でスタブ曲に設定してから
`presentation = .nowPlaying`に切り替える。スクリーンショット
`/tmp/claude-501/tvfix_nowplaying_live.png`で、詳細画面から遷移した直後に
タイトル「検証用スタブ曲」・アーティスト「UX Music Demo」・進捗「0:12 / 3:00」・
一時停止アイコンが表示されることを確認——修正前の「初期/空画面」ではなく、実際の
トラック状態が即座に反映されることを確認した。

## 追記（2026-08-13）: 「Now Playingが継続的に死んでいる」実機再報告の再調査

上記コミット（`c3fbcc7`）の検証は `TVDetailPlayPreviewHarness` の**静止画スクリーンショット1枚**
だったため、「一度は正しい値で描画されたが、以後は更新されないスタブ表示」と「本当にライブ
更新されている表示」を区別できていなかった。実機からの再報告を受け、ゼロから再調査した。

### 調査した経路（問題なしと確認）

- **`MusicPlayerService`の観測方式**: `@Observable`（Observation framework）で、`TVNowPlayingView`
  および配下の `TVNowPlayingProgressBar` 等は `player` を素の `let` プロパティとして受け取り、
  `body` 内で `player.positionSeconds` 等を直接読んでいる。`@Observable` はトップレベルで
  読んだプロパティを自動追跡するため、`@ObservedObject`/`@Bindable` などのラッパーなしで
  正しく動作する構成——`progress/watch-transfer-ui-observation.md` が警告する「`@Observable`
  親の中に裸の `ObservableObject` 子をネストする」罠には該当しない（`MusicPlayerService` 自体が
  `@Observable` であり、`ObservableObject` の子を持っていない）。
- **進捗を駆動するタイマー**: `MusicPlayerService.init()` が無条件に `startPositionTimer()` を
  呼び、`Timer(timeInterval: 0.25, repeats: true)` を `RunLoop.main` に `.common` モードで
  登録している（tvOS も含め全プラットフォーム共通、`configureForPreview` 等の分岐なし）。
  `tickPlaybackPosition()` は `AVAudioPlayerNode.lastRenderTime` から実時間を計算するため、
  実際に音声が再生されていれば `positionSeconds` は確実に進む。
- **play/pause/トラック変化のUI反映**: `TVNowPlayingTransportBar` は `player.togglePlayPause()`/
  `player.next()`/`player.previous()` を直接呼び、戻り値の状態変化は上記の `@Observable`
  自動追跡で反映される。

### 実機同等の検証で確認した結果: 現行コードは正しく動作している

`TVDetailPlayPreviewHarness`（`configureForPreview` によるスタブ静止値）ではなく、
**実際にAVAudioEngineで再生する経路**を実機相当で検証する必要があったため、新設の
DEBUG専用ハーネス `TVLiveNowPlayingHarness`（`UXTV_PREVIEW=livenowplaying`、
`UXMusicTVApp.swift`）を追加した。稼働中のライブホスト（`http://127.0.0.1:8765`、実ライブラリ）
に対して本物の `TVPlaybackController.play` → `MusicPlayerService.play` を実行し
（`masterVolume = 0` でミュート、`progress/tvos-playback.md` の速度改修と同じ経路）、
実際に鳴っている（はずの）曲の `TVNowPlayingView` を約6秒間隔で2回スクリーンショット
（`/tmp/claude-501/npfix_t0.png`・`npfix_t6.png`）した結果、進捗表示が **0:03 → 0:09**
（一時停止アイコン表示、= 再生中）と正しく進んでいることを確認した。つまり
`MusicPlayerService`→`TVNowPlayingView`の観測チェーン自体は、現在のコードで壊れていない。

### それでも見つけた、実際に壊れうる箇所（防御的に修正）

`TVPairingView.swift`の`TVConnectedView`（`TVBrowseView`に`player`を渡す組み立て役）を精査した
ところ、`player`と`remoteControlServer`が**参照型（クラス）でありながら素の`let`プロパティ**
として`init`内で構築されていた:

```swift
private let player: MusicPlayerService     // ← 修正前
private let remoteControlServer: TVRemoteControlServer  // ← 修正前
init(model: TVAppModel) {
    let sharedPlayer = MusicPlayerService()
    player = sharedPlayer
    _playbackController = StateObject(
        wrappedValue: TVPlaybackController(client: apiClient, player: sharedPlayer)
    )
    ...
}
```

`TVConnectedView`は`struct View`なので、親（`TVRootView`、`model: TVAppModel`を`@ObservedObject`
で観測）が再レンダリングされるたびに`init`が再実行される。`@StateObject`（`playbackController`
など）は`wrappedValue`の自動クロージャが**初回のみ**評価され、以後は同一インスタンスを
保持し続けるのに対し、素の`let`はビューの構造的アイデンティティが保たれていても**再init毎に
毎回新しい`MusicPlayerService()`/`TVRemoteControlServer`が作られて代入される**。つまり
2回目以降の再initが発生すると、`playbackController`は初回の`sharedPlayer`を握ったまま実際に
音声を再生し続ける一方、`TVBrowseView`/`TVNowPlayingView`へ渡る`player`は毎回差し替わった
「一度も`play()`されていない別インスタンス」になり得る——これはまさに「実際に鳴っている
プレイヤーと画面が観測しているプレイヤーが別物になる」種類の、ログにもクラッシュにも出ない
静かな死んだNow Playingを引き起こしうるバグで、`watch-transfer-ui-observation.md`が警告する
Observationの罠と同系統（今回は`@Observable`×`ObservableObject`の混在ではなく、
「`struct View`の`let`格納プロパティは再init毎に再評価される」というSwiftUIの基本仕様を
参照型プロパティに対して見落としたケース）。

現在の`TVAppModel`は`pairingState`/`serverConfig`の2つの`@Published`のみを持ち、接続完了後の
通常運用ではどちらも変化しないため、この再initは通常セッションでは起きないと考えられる
（=今回の実機再現ができなかった理由と整合する）。ただし将来`TVAppModel`に別の`@Published`
状態を足したり、`TVConnectedView`の親階層が変わった場合に静かに再発しうる地雷であるため、
`@StateObject`と同じ「初回のみ評価・以後は同一インスタンスを保持」という意味論を持つ`@State`
（参照型に対しても同じ保証を提供する）へ変更し、構造的に再発を防止した:

```swift
@State private var player: MusicPlayerService
@State private var remoteControlServer: TVRemoteControlServer
...
_player = State(initialValue: sharedPlayer)
_remoteControlServer = State(initialValue: TVRemoteControlServer(...))
```

### 検証

- `xcodebuild test`（`UX-Music-TV`スキーム、tvOSシミュレータ）: 全件成功。
- 実際のライブホストに対する再生で進捗が0:03→0:09と進むスクリーンショットにより、
  観測チェーン自体が正しく動作することを実証済み（上記）。
- `TVConnectedView`の`@State`化はコンパイル成功のみ確認——再init自体を実機で誘発する
  再現手順が無いため、この防御的修正そのものをスクリーンショットで直接反証／実証すること
  はできていない（コード上の構造的保証としては`@StateObject`と同じ強度）。
