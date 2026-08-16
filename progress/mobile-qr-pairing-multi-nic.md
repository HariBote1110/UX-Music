# QRペアリングの複数NIC対応

## 背景
デスクトップ（Mac）が複数のLAN IP（Wi-Fi/有線/Tailscale等）を持つ場合、
ペアリングQR (`uxmusic://pair?host=&port=&secret=`) には
`GetLANServerAddress()` が返す1つのIPしか埋め込まれなかった。
iPhoneがそのIPと別サブネット/NICにいると `POST /v1/pairing/redeem`
が届かず、ペアリングがサイレントに失敗していた。

mDNS Discovery経路には既に複数候補フェイルオーバー
（`RemoteConnectionResolver`/`RemoteConnectionCandidates`、
`ServerConfig.fallbackHosts`、`AppModel.withFailover`）が実装済み
だったが、QR→redeem経路には存在しなかった。

## 決定
- デスクトップ側 (`server/app_remote.go`): `BuildPairingURL` に
  `hosts=`（カンマ区切り・全LAN IPv4アドレス、プライマリが先頭）を
  追加。`lanIPv4Addresses()` で loopback・link-local(169.254.*)を
  除外して列挙。`host=` は後方互換のため維持。Tailscale等の仮想IF
  も除外しない（現に到達可能な場合があるため）。
- モバイル側 (`Models/ServerConfig.swift`): `PairingRequest` に
  `hosts: [String]` を追加。`hosts=`欠如（旧QR）時は `[host]` に
  フォールバック。
- モバイル側 (`App/AppModel.swift`): `redeemPairing(hosts:port:secret:)`
  を新設。`RemoteConnectionResolver.resolve` で `GET /v1/identity`
  に応答する候補を探索してからその1台にredeemし、成功時は残りの
  候補を `serverConfig.fallbackHosts` に保存（Discovery経路と
  同じ挙動に統一）。全滅時は `pairingError` に
  「デスクトップに到達できません。同じ Wi-Fi に接続しているか
  確認してください。」を設定。
- `applyPairingURL` はURLパース失敗時（旧形式・壊れたQR含む）にも
  `pairingError`（「QRコードを読み取れませんでした。デスクトップ
  アプリを最新版に更新してください。」）を設定し、サイレント失敗を
  排除。SettingsScreenのQRスキャンフローは既に
  `model.pairingError` を `pingResult` に反映する実装だったため
  UI側の追加変更は不要だった。

## 代替案として検討したもの
- モバイル側で全候補に並行してredeemを試す案 → 却下。
  secretはワンタイム値のため、複数候補に同時redeemすると
  1台目で消費された時点で残りが失敗し扱いが複雑になる。
  reachability確認（`/v1/identity`、認証不要）→ 到達した1台のみに
  redeemする方式の方がDiscovery経路と一貫し、secretの単発性とも
  整合する。

## Gotcha
- `lanIPv4Addresses()` は開発機で複数エントリを返すため、
  `TestBuildPairingURL_hostsParamListsAllLANAddresses` は実環境
  依存になる（CI環境でNICが1つしかなければ `hosts=` は1要素の
  リストになるが、それでもテストの主張（`host`が`hosts`に含まれる
  こと）は満たされる）。
