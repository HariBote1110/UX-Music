# watchOS バックグラウンド再生が効かない問題（Info.plist）

## Decision
- 根本原因: `project.pbxproj` の watch ターゲット（Debug/Release 両方）に
  `INFOPLIST_KEY_WKBackgroundModes = audio;` を設定していたが、
  `GENERATE_INFOPLIST_FILE = YES` が生成する Info.plist はこのキーを
  一切反映しない。実際にビルドした `UX-Music-Watch.app/Info.plist` を
  `plutil` でダンプして `WKBackgroundModes` が存在しないことを確認済み。
  結果としてアプリがバックグラウンドに回ると watchOS がオーディオを
  サスペンドしていた。
- 修正: `UX-Music-Watch/Info.plist` を新設し、`WKBackgroundModes = [audio]`
  を直接宣言。両ビルド設定に `INFOPLIST_FILE = "UX-Music-Watch/Info.plist";`
  を追加し（`GENERATE_INFOPLIST_FILE = YES` は生成キーとソース Info.plist
  をマージするため共存可能）、無効だった `INFOPLIST_KEY_WKBackgroundModes`
  は削除した。
- 検証: `UX-Music-MobileTests/WatchBackgroundAudioInfoPlistTests.swift` を
  先に追加（Red）→ 修正後に Green。さらに watch スキームを
  `generic/platform=watchOS Simulator` 向けにビルドし、
  `plutil -p .../UX-Music-Watch.app/Info.plist` で
  `WKBackgroundModes => ["audio"]` が実際に含まれることを確認した。

## Alternatives considered
- Info.plist を完全に手動管理する（`GENERATE_INFOPLIST_FILE = NO`）方式は、
  他の自動生成キー（`CFBundleDisplayName` 等、`INFOPLIST_KEY_*` 経由）まで
  すべて手動記述に戻す必要があり、変更範囲が不必要に広がるため不採用。
  最小の Info.plist をマージする方式（`INFOPLIST_FILE` + `GENERATE_INFOPLIST_FILE = YES`
  の併用）で十分だった。

## Constraints / Gotchas
- `INFOPLIST_KEY_*` 系のビルド設定は Xcode が Info.plist 生成時に理解する
  キーのホワイトリストに依存しており、`WKBackgroundModes` のように
  Xcode 側が未対応のキーは静かに無視される（ビルドエラーにもならない）。
  同様の背景モード系キーを追加する場合は、必ずビルド後の Info.plist を
  `plutil` 等で確認すること。
