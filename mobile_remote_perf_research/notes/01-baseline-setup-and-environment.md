# 計測環境・再現手順

## 目的 / 仮説

iOS版「Remote」まわり（Remoteタブ = `RemoteLibraryScreen` と Controlタブ =
`RemoteControlScreen`）が「全体的に重い」というユーザー報告について、実機なしで
デスクトップとペアリングした状態を再現し、CPU/メモリを実測できる環境を整える。
ペイン切替時の再計算コストは`UX-Music-Mobile/progress/mobile-ux-fixes-2026-08.md`
7項で既に修正済み（`LibraryDerivedCollections.RemoteInputs`）なので、それ以外の
系統的原因を洗い出す。

## 環境

- ホスト: macOS 26.5.2 (Build 25F84)
- Xcode 26.5 (Build 17F42)
- シミュレータ: iPhone 17 (iOS, UDID `BB3F0F4C-2D5C-4C21-AA96-85E8A8A77AA5`)
- コミット: `31ccd80b95fa168b073321403fc6e01172e9cb39`（ブランチ
  `feature/native-queue-background`）
- ダミーライブラリ: N=500曲、5アルバム、3アーティスト

## 手順（再現ハーネス）

既存の`scripts/sidecar_stub_server.py`と`UXM_DEBUG_SIDECAR_HOST`/
`UXM_DEBUG_SIDECAR_PORT`デバッグフック（`UXMusicMobileApp.swift`）を再利用した。
このフックは`sidecarPollOnce`用に作られたものだが、実体は`model.serverConfig`を
直接スタブのhost/portに差し替えているため、`RemoteLibraryScreen`/
`RemoteControlScreen`が使う`model.withFailover`経由の全リクエストもそのまま
スタブに向く（ペアリングQRを経由せず、トークンチェックも無いので追加の
UserDefaults仕込みは不要）。

`/v1/remote/songs`・`/v1/identity`・`/v1/remote/loudness`・
`/v1/remote/situation-playlists`・`/v1/remote/playlists`・
`/v1/remote/artwork/`・`/v1/remote/state`を追加実装したスタブを新設:
`mobile_remote_perf_research/tools/remote_stub_server.py`
（`Models/Song.swift`の`CodingKeys`に合わせてJSONフィールド名を厳密一致させた）。

```bash
# 1. スタブサーバー起動（N=500曲）
python3 mobile_remote_perf_research/tools/remote_stub_server.py --port 8799 --songs 500 &

# 2. ビルド（DerivedDataは研究ディレクトリ配下、既存ビルドに影響しない）
xcodebuild -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -scheme UX-Music-Mobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=BB3F0F4C-2D5C-4C21-AA96-85E8A8A77AA5' \
  -derivedDataPath mobile_remote_perf_research/DerivedData \
  build -collect-test-diagnostics never

# 3. シミュレータ起動・インストール・スタブ指定で起動
xcrun simctl boot BB3F0F4C-2D5C-4C21-AA96-85E8A8A77AA5
xcrun simctl install BB3F0F4C-2D5C-4C21-AA96-85E8A8A77AA5 \
  mobile_remote_perf_research/DerivedData/Build/Products/Debug-iphonesimulator/UX-Music-Mobile.app
SIMCTL_CHILD_UXM_DEBUG_SIDECAR_HOST=127.0.0.1 SIMCTL_CHILD_UXM_DEBUG_SIDECAR_PORT=8799 \
  xcrun simctl launch BB3F0F4C-2D5C-4C21-AA96-85E8A8A77AA5 com.uxlabs.uxMusicMobile

# 4. CPU/RSSサンプリング（1Hz、60秒）
PID=$(pgrep -f "UX-Music-Mobile.app/UX-Music-Mobile")
for i in $(seq 1 60); do ps -o pid,pcpu,rss -p $PID | tail -1; sleep 1; done
```

シミュレータUI操作は`mcp__Claude_Code_iOS_Simulator__control`（attach/tap/
screenshot）を使用。設定画面で接続先が`127.0.0.1:8799 (自動)`・LANチェック済みに
なっていることを確認済み（デバッグフックが正しく`serverConfig`を書き換えている
証拠）。

## 結果

再現ハーネス自体は正常動作を確認: Remoteタブで`Stub Album A`〜`E`のグリッドが
表示され、Controlタブで`Stub Track Title` / `Stub Artist`の再生状態（トグル可能な
Pause/Play含む）が表示された。以降のノートの実測はこの環境で取得。

## 結論

- 実機なしでの再現環境構築は成功。ペアリングフロー・トークン検証を経由せず
  `serverConfig`を直接差し替えられるため、以後のA/B計測はこのハーネスで
  高速に回せる。
- `mobile_remote_perf_research/tools/remote_stub_server.py`はメンテナンスコストが
  ある（`server/app_remote.go`のJSON形状変更に追従が必要、`sidecar_stub_server.py`
  と同種の既知の負債）。

## 次の一手 / 未検証事項

- タッチ自動操作でのペイン切替（Songs/Albums/Playlistsページング）連続実行時の
  CPUは、シミュレータ操作の座標系変換に時間を要したため今回は未計測
  （後述のH1/H2はアイドル時のみ計測）。
