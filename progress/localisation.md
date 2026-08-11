# iOS/Watch アプリの多言語対応（en/ja String Catalog）

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

### 未対応（意図的に今回のスコープ外）

以下のファイルにはまだ日本語ハードコード文字列が残っている（`grep -rlP '[\x{3040}-\x{30FF}\x{4E00}-\x{9FFF}]'`
で検出可能）。iOS アプリ全体は 12,000 行超・40 ファイル規模で、1 セッションでの完全対応には至らなかった:

`Views/LibrarySegmentedHeader.swift`, `Views/AlbumDetailView.swift`, `Views/ArtistDetailView.swift`,
`Views/RemoteLibraryScreen.swift`, `Views/RemotePlaylistDetailView.swift`, `Views/SongRowView.swift`,
`Views/NowPlayingLyricsScreen.swift`, `Views/AddYouTubeLinkSheet.swift`, `Views/LocalLibraryScreen.swift`,
`Views/PlaylistDetailView.swift`, `Views/RemoteControlScreen.swift`, `Views/DesktopPlaylistImportView.swift`,
`Views/HomeRootView.swift`（ホーム画面下部タブの "Library"/"Remote"/"Control" が英語のまま「設定」とだけ日本語、
という stray が実機で確認できる既知の不整合)、
`Core/CollectionSortOrder.swift`, `Core/LibrarySortOrder.swift`（`testDisplayNamesAreJapanese` が既存のまま残っている）,
`Core/LyricsTranslationMerger.swift`, `Core/WatchTransferMenuPolicy.swift`,
`Services/MusicPlayerService.swift`, `Services/RemoteAPIClient.swift`, `Services/YouTubeEmbedPlayer.swift`,
`Services/LibraryMembershipStore.swift`

これらは次のセッションで同じ手順（キー抽出 → 両カタログへ追記 → コード側をキー文字列に置換 → 該当テストを
`String(localized:)`/`localizedString(_:locale:)` 参照に更新）で続行できる。`LocalizationCatalogCompletenessTests`
は「カタログに載っているキーが両言語そろっているか」だけを保証するもので、「まだカタログに載っていない stray
文字列がないか」までは検出しない（用途外）。

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

## 言語を追加する場合

1. 各 `Localizable.xcstrings` の `strings.<key>.localizations` に新しいロケールのキーを追加する
   （`{"state": "translated", "value": "..."}`）。
2. `project.pbxproj` の `knownRegions` に追加する。
3. `LocalizationCatalogCompletenessTests.requiredLocales` に追加すれば、そのロケールの翻訳漏れもテストで検出される。
