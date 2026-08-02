# DeviceIdentity のゼロUUID誤登録バグ修正

## Decision
- `UIDevice.identifierForVendor` はシミュレータ等で `00000000-0000-0000-0000-000000000000`（ゼロUUID）を返すことがあり、これを無条件で `deviceId` として採用・永続化していたため、複数端末がデスクトップ側 `deviceAuthTokens` に同一IDで登録される衝突が発生していた。
- `DeviceIdentity` にゼロUUID（および `nil`/空文字）を無効値として弾く純粋関数 `resolvedDeviceId(existing:vendorId:generateFallback:)` を切り出し、無効な場合は生成済みフォールバックUUIDを使うよう修正。
- 過去に誤ってゼロUUIDが永続化されていたケースも `existing` 側の検証で拾い、次回アクセス時にフォールバックへ差し替える。

## Alternatives considered
- 起動時に一度だけ判定してキャッシュする案 → `UserDefaults` に既存の壊れた値が残っている場合の救済ができないため却下。

## Constraints / Gotchas
- `resolvedDeviceId` は UIKit 非依存の純粋関数としてテスト可能にしてある（`UX-Music-MobileTests/DeviceIdentityTests.swift`）。実機依存のシミュレータ挙動を直接テストするのは困難なため、この切り出しが必須。
