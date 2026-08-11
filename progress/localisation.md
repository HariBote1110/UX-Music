# iOS/Watch アプリの多言語対応（en/ja String Catalog）

**状態: 完了（2026-08-11）**。iOS アプリの日本語ハードコード文字列の全数スイープが完了し、
`grep -rlP '[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]'` でユーザー向け View/Service/Core 層に該当する
ヒットは無い（コメント・ログ・データ照合用リテラルを除く。詳細は下記「意図的に未対応のまま残したもの」）。

## 決定事項

- **String Catalog を手書きで導入**: `UX-Music-Mobile/UX-Music-Mobile/Localizable.xcstrings`（iOS アプリターゲット）と
  `UX-Music-Mobile/UX-Music-Watch/Localizable.xcstrings`（Watch アプリターゲット）の 2 つ。CLI 環境で作業しているため
  Xcode の自動抽出は使わず、xcstrings の JSON フォーマット（`sourceLanguage`/`strings`/`version`）を直接生成する Python
  スクリプトで書き出した。両方とも `project.pbxproj` の該当ターゲットの `PBXResourcesBuildPhase` に手動登録済み
  （このプロジェクトは `objectVersion 63` で synchronised groups を使っていないため、新規リソースは
  `PBXBuildFile` / `PBXFileReference` / グループ children / Resources ビルドフェーズの 4 箇所に手で追記する必要がある）。
  `knownRegions` にも `ja` を追加した。
- **キーは英語文字列そのもの**: 既存の英語ハードコードはそのままキーとして使う。日本語ハードコードは自然な英語に
  書き起こしてキー化した（例: 「ダウンロード音質」→ `"Download Quality"`）。すべてのキーに `en`/`ja` 両方の
  `translated` な `stringUnit` を用意している。
- **SwiftUI の `Text`/`Button`/`Label`/`Picker` などの文字列リテラルは `LocalizedStringKey` として自動的にカタログを
  参照する**ため、キーと一致する文字列を渡すだけでよい。モデル層・`String` を返す関数は `String(localized:)` を使用。
  補間を含む文字列（`"Connected to \(host)"` など）は `String(format: String(localized: "Connected to %@"), host)`
  の形にして、xcstrings 側のキーを `%@` プレースホルダ付きで用意した。
- **翻訳不要な補間文字列は `Text(verbatim:)` にした**（例: `"UX Sync \(protocolVersion)"` のようにブランド名+バージョン
  番号だけで翻訳の意味がないもの）。カタログのキーを不必要に増やさないための判断。

## 対応した範囲

- `Views/NowPlayingView.swift`（設計書で名指しされた最優先ファイル。約 40 個のユーザー向け文字列）
- `Views/SettingsScreen.swift`（同じく最優先ファイル。接続先/ペアリング/Watch/ダウンロード品質まわりすべて）
- `Views/WatchTransferMenuItems.swift` と、その `title` を渡している 6 ファイル
  （`AlbumDetailView.swift` / `ArtistDetailView.swift` / `RemoteLibraryScreen.swift` /
  `RemotePlaylistDetailView.swift` / `PlaylistDetailView.swift` / `LocalLibraryScreen.swift`）— Apple Watch 転送の
  コンテキストメニュー文言のみ
- モデル層: `Core/DownloadAudioQuality.swift`（`displayName`）、`Services/WatchAudioTranscoder.swift`
  （`TranscodeError.errorDescription`）、`Services/WatchTransferBridge.swift`（ダウンロード失敗理由）、
  `App/AppModel.swift`（ペアリングエラー文言）
- Watch ターゲット: `WatchAudioPlayerService.swift`（`routeError`）、`WatchQueueVolumeView.swift`、
  `WatchRootView.swift`（受信中トースト）、`WatchNowPlayingView.swift`、`WatchSongListView.swift`
  （Watch 側は日本語ハードコードを洗い出した結果、この 5 ファイルで全件だった）

### 続行セッションで完了（2026-08-11）

前回セッションが未対応としてリストした残りファイルすべてに対応し、iOS アプリの en/ja 対応スイープを完了した:

`Views/LibrarySegmentedHeader.swift`, `Views/AlbumDetailView.swift`, `Views/ArtistDetailView.swift`,
`Views/RemoteLibraryScreen.swift`, `Views/RemotePlaylistDetailView.swift`, `Views/SongRowView.swift`,
`Views/NowPlayingLyricsScreen.swift`, `Views/AddYouTubeLinkSheet.swift`, `Views/LocalLibraryScreen.swift`,
`Views/PlaylistDetailView.swift`, `Views/RemoteControlScreen.swift`, `Views/DesktopPlaylistImportView.swift`,
`Core/CollectionSortOrder.swift`, `Core/LibrarySortOrder.swift`,
`Services/MusicPlayerService.swift`（YouTube 再生エラー・スキップ通知の2文字列のみ。ログ/print/JSブリッジ文字列は対象外）,
`Services/YouTubeEmbedPlayer.swift`（`errorMessage(code:)` の全ケース）。

`UX-Music-Mobile/Localizable.xcstrings` に 101 キーを追加（119 → 220）。カウント内訳（曲数・アルバム数などの
`%ld`/`%@` プレースホルダ付きキー約10個を含む）は git 履歴のコミット差分を参照。

**実機報告のホームタブバー混在バグを特定・修正**: `Views/HomeRootView.swift` の `Label("Library"...)` /
`Label("Remote"...)` / `Label("Control"...)` は元々コード上は英語リテラルのままで、`String Catalog` に
`"Library"`/`"Remote"`/`"Control"` キー自体が一度も登録されていなかった（前回セッションが `SettingsScreen.swift`
の `"Settings"` キーだけ登録し、`HomeRootView.swift` はスコープ外としていたため）。カタログに存在しないキーは
黙って元のリテラル文字列にフォールバックするため、ja ロケールでは「ライブラリ」ではなく英語の "Library" が
表示され、"設定" だけ日本語という stray になっていた。`Library`→`ライブラリ`、`Remote`→`リモート`、
`Control`→`コントロール` の3キーを追加して解消。シミュレータでの ja/en 両ロケール実機確認で修正を確認済み。

`Core/WatchTransferMenuPolicy.swift` はドキュメントコメント以外に日本語/英語ハードコードのユーザー向け文字列が
存在せず対応不要だった。

### 意図的に未対応のまま残したもの

- `Services/RemoteAPIClient.swift` / `Services/LibraryMembershipStore.swift`: 日本語はすべてドキュメントコメント内
  （`"ライブラリに追加"` 等をコメントで参照しているだけ）で、ユーザーに表示される文字列は存在しない。
- `Core/LyricsTranslationMerger.swift` の `interludeMarkers`（`"[間奏]"` など）: UI 表示文字列ではなく、保存済み
  歌詞ファイルの間奏マーカーをパースするためのデータ照合用リテラル。翻訳すると既存の保存済み `.lrc`/`.txt`
  ファイルとのマッチングが壊れるため、意図的に翻訳対象外とした。
- `Services/MusicPlayerService.swift` / `Services/YouTubeEmbedPlayer.swift` のログ/`print`/デバッグコメント中の
  日本語（例: `WatchTransferBridge.swift` の `print("...Watch向けAACトランスコードに失敗...")`）: ユーザーに
  到達しないため対象外。

`LocalizationCatalogCompletenessTests` は「カタログに載っているキーが両言語そろっているか」だけを保証するもので、
「まだカタログに載っていない stray 文字列がないか」までは検出しない（用途外）。今回のスイープはコード側の
`grep -rlP '[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]'` による日本語ハードコード全数チェックと、シミュレータでの
ja/en 両ロケール目視確認（ホームタブバー・ライブラリ一覧の空状態表示）で仕上げた。

## pingResult の色分けロジックの副作用修正

`SettingsScreen.swift` の接続テスト結果表示は、以前は `pingResult`（表示文字列）が `"Connected"` で始まるかどうかで
緑/赤を判定していた。この文字列を翻訳すると日本語ロケールで判定が壊れるため、`pingIsHealthy: Bool` を新設し、
各 `pingResult` 代入箇所で明示的に設定するよう変更した（表示文字列とロジック用フラグを分離）。

## テストの扱い

- 完全一致で日本語文字列をアサートしていた既存テストは削除・弱体化せず、`String(localized:)` と同じ
  `Bundle.main` 経由のカタログ参照に置き換えた。新設した `LocalizationTestHelpers.localizedString(_:locale:)`
  で `en`/`ja` 両方の翻訳値を直接ピン留めできる（`DownloadAudioQualityTests`、`AppModelFailoverTests`）。
- `LocalizationCatalogCompletenessTests`（新規）: 2 つの `.xcstrings` を直接 JSON パースし、全キーに `en`/`ja` 両方の
  `translated` かつ非空の翻訳があることを保証する。
- `LibrarySortOrderTests.testDisplayNamesAreJapanese` / `CollectionSortOrderTests.testAlbumDisplayNamesAreJapanese` /
  `testArtistDisplayNamesAreJapanese`: `displayName` を翻訳キー化したのに合わせ、`testDisplayNamesAreLocalized` /
  `testAlbumDisplayNamesAreLocalized` / `testArtistDisplayNamesAreLocalized` にリネーム。`displayName` の現在ロケール
  参照に加えて `localizedString(_:locale: "ja")` で既存の日本語値を、`localizedString(_:locale: "en")` で新設の
  英語値をそれぞれピン留めするアサーションを追加（弱体化ではなく強化）。
- `YouTubeEmbedPlayerTests`: `errorMessage(code:)` の各ケースを `localizedString(_:locale:)` で en/ja 両方ピン留め
  しつつ、`errorMessage(code:)` 自体の戻り値は現在ロケール（テストホストの既定ロケール）と比較する形に変更。
  この過程で気づいた点: このリポジトリのテストホストは既定ロケールが `ja`（英語ではない）。`String(format:)` の
  結果を決め打ちで英語文字列と比較すると現在ロケールが ja の環境で落ちるため、`DownloadAudioQualityTests` と同じ
  「`displayName`/`errorMessage` は current-locale lookup と比較、個別の en/ja 値は `locale:` 明示で別途ピン留め」
  という規約に統一した。

## 言語を追加する場合

1. 各 `Localizable.xcstrings` の `strings.<key>.localizations` に新しいロケールのキーを追加する
   （`{"state": "translated", "value": "..."}`）。
2. `project.pbxproj` の `knownRegions` に追加する。
3. `LocalizationCatalogCompletenessTests.requiredLocales` に追加すれば、そのロケールの翻訳漏れもテストで検出される。
