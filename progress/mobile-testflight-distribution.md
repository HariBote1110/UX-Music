# UX Music Mobile の TestFlight 配布

## Decision
- バンドル ID を `com.uxlabs.uxMusicMobile` 系から `jp.ux-labs.UXMusicMobile` 系へ変更（2026-10-26、ユーザー判断）。チームの他アプリ（UX Inkwell・UX Circle Navigator）と命名を揃えるため。App Store Connect のアプリ記録を作ると変更不可なので、作成前に確定した。
  - iOS: `jp.ux-labs.UXMusicMobile` / Watch: `.watchkitapp` / TV: `.tv`（TV は未配布）
- `ITSAppUsesNonExemptEncryption = NO`（iOS アプリ）。暗号化は OS の HTTPS と CryptoKit の SHA-256 ハッシュのみで、輸出規制の免除対象。
- まずは内部テスト（審査なし）で配布。外部テストは Beta App Review で YouTube 関連機能が問題視される恐れがあるため保留。
- アップロードは `~/.blitz/asc-credentials.json` の App Store Connect API キーを使った `xcodebuild -exportArchive`（自動署名・`-allowProvisioningUpdates`）。

## Constraints / Gotchas
- バンドル ID が変わったため、旧 ID で入れた開発版とは別アプリ扱い（設定・ダウンロード済み曲・Keychain は引き継がれない）。
- TV ターゲットはこの Mac に tvOS プラットフォームが無くビルドできない。Archive は iOS（Watch 同梱）のみ。
- `progress/` 内の過去メモにある `simctl launch com.uxlabs...` は旧 ID。
- Watch の `WKBackgroundModes` に `audio` を入れるとアップロードが拒否される（エラー 90362: Invalid Info.plist value）。`audio` は `WKBackgroundModes` の有効値ではない。Watch の音声のバックグラウンド再生は `UIBackgroundModes = audio` だけで宣言する（2026-10-26 に削除）。削除後の実機での動作は未確認。
- 内部テストグループ「Internal」は `hasAccessToAllBuilds = false`。アップロードしただけではテスターに届かない（`internalBuildState` が `READY_FOR_BETA_TESTING` のまま止まる）。処理が終わったら、App Store Connect API の `POST /v1/betaGroups/{id}/relationships/builds` でビルドをグループに追加する。追加すると `IN_BETA_TESTING` になる（ビルド 4 で発生、2026-10-27）。
- zsh では `AUTH="-a -b"` を `$AUTH` で展開しても語分割されない。xcodebuild の認証引数は配列 `AUTH=(...)` で `"${AUTH[@]}"` と渡す。

## TestFlight 版で見つかったペアリング導線の問題（2026-10-27）
- Discovery は接続先を選ぶだけで、ペアリング（トークン取得）はしない。新規インストールでは認証が通らず、ライブラリが空のままになっていた → 未ペアリングならその場で QR スキャナを開く（カメラが無ければペアリングコード欄へ）ように変更。
- QR に入る候補アドレスは、デスクトップの全 IPv4（別サブネット・Tailscale・Parallels のブリッジを含む）。iOS がこれを先頭から順に試し、届かない候補ごとに最大 10 秒待っていた → `RemoteConnectionResolver.resolve` を並列化し、最初に応答した候補を採用（候補の並び順は保証しない）。
- QR カメラの設定を main から専用のシリアルキューへ移した（実機での体感は未確認）。
