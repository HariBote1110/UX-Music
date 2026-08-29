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

## 追補: `WKBackgroundModes` 適用後も実機で再生が止まる（未解決）

- 事象: 上記修正でビルド済み Info.plist に `WKBackgroundModes = [audio]`
  が入っていることを確認済みにもかかわらず、実機（Apple Watch + AirPods
  接続済み）でアプリをバックグラウンドに回した瞬間に再生が停止する。
  シミュレータでは検証できない（Bluetooth ルートを再現できない）ため、
  実機ログでの切り分けが必須。
- 仮説: `WatchAudioPlayerService.activateAudioSession` が試みる
  `.playback`/`.longFormAudio` の `AVAudioSession` アクティベートが実機上
  で静かに失敗し、`.playback`/`.default`（route-sharing policy なし）の
  フォールバックに落ちているのではないか、というもの。フォールバック経路
  はフォアグラウンドでは Bluetooth 出力へも問題なくルーティングされるため
  気づきにくいが、`.longFormAudio` でない素の `.playback` セッションは
  バックグラウンドで watchOS にサスペンドされる可能性が高い。
  従来のコードはこのフォールバック発生時、および `activated == false` かつ
  `error == nil` のケースで一切ログを出しておらず、実機コンソールだけでは
  どちらの経路を通ったか判別できなかった。
- 追加した診断（本コミット、実装は未検証＝次回実機実行待ち）:
  - `WatchAudioPlayerService.activate` / `activateAudioSession` /
    `applyRouteOutcome` に `[WatchAudioPlayer]` プレフィックス付きログを
    網羅的に追加。どちらのポリシーを試行したか、`activated`/`error`
    （エラーなしの場合も明示）、適用後の実際の
    `AVAudioSession.sharedInstance().currentRoute.outputs`（ポートタイプ・
    ポート名）まで出力する。
  - `WatchAudioPlayerService.sessionDiagnostic`（`@Published`, DEBUG限定）
    を追加し、`applyRouteOutcome` の結果を "longForm / AirPods Pro" や
    "fallback / Speaker" のような短い文字列として保持。
    `WatchNowPlayingView` の操作ボタン群の下に `#if DEBUG` 限定・
    9pt グレーの極小キャプションとして表示する（リリースビルドには一切
    出力しない）。ケーブルを繋がずに手首から外れた実機の状態を確認する
    手段がコンソールログだけでは不十分なための対策。
  - 副次的な修正: `WatchAudioActivationPolicy`（純粋ロジック、
    `UX-Music-MobileTests/WatchAudioActivationPolicyTests.swift` でテスト
    済み）を新設し、前回 `.longFormAudio` が成功済みなら次回の
    `activateAudioSession` で `setCategory`/`activate` を再実行せず
    スキップするようにした。実機で観測された `SessionCore.mm:631`
    （メインスレッドでアクティブなセッションに再度アクティブ化を試みた
    際の警告）はこの再設定が原因と見て対処。既にフォールバック中だった
    場合は、Bluetooth 機器が後から接続された可能性を考慮し、毎回
    `.longFormAudio` を再試行する。
- 次回実機実行で確認すべきこと:
  - コンソールで `[WatchAudioPlayer] activateAudioSession: previouslyActivated=... plan=...`
    → `[WatchAudioPlayer] activate: attempting category=... policy=...`
    → `[WatchAudioPlayer] activate result: policy=... activated=... error=...`
    → `[WatchAudioPlayer] applyRouteOutcome: outcome=... route=[...]`
    の一連の流れを、バックグラウンド遷移の直前・直後それぞれで確認し、
    `policy=longFormAudio` の `activated` が `true`/`false` のどちらか、
    `false` の場合の `error` の内容を特定する。
  - Now Playing 画面下部（DEBUGビルドのみ）に表示される極小キャプション
    （"longForm / ..." か "fallback / ..." か）を、バックグラウンドに
    回す直前に確認する。`fallback` のまま推移している場合は仮説が正しい
    ことになる。
  - まだ根本修正（フォールバック発生時にどう本来の longFormAudio を
    確実に成立させるか）には着手していない。今回はあくまで原因切り分け
    のための可観測性強化と、無駄な再アクティベートの解消に留まる。

## 追補2: 真因は `UIBackgroundModes` 未宣言（Apple公式ドキュメントで裏付け）

- 実機ログにより `.longFormAudio` でのセッションアクティベートは
  成功していることを確認済み（`activated=true`、フォールバック経路は
  通っていない）。にもかかわらずバックグラウンド遷移直後に再生が停止
  していたため、上記「追補」の仮説（フォールバック経路）は棄却された。
- 原因: Apple の watchOS Keys ドキュメント（Info.plist キー一覧の
  アーカイブ）によれば、Watch アプリがユーザー操作終了後もオーディオ
  再生のために動作し続けるには `UIBackgroundModes`（値 `audio`）が
  必要であり、このキーが無いとユーザー操作が止まった時点で再生も止まる
  と明記されている。一方 `WKBackgroundModes` はワークアウト処理系の
  バックグラウンドセッション向けのキーであり、オーディオ継続用途とは
  別物。本プロジェクトの `UX-Music-Watch/Info.plist` には
  `WKBackgroundModes = [audio]` のみが存在し、`UIBackgroundModes` が
  欠落していた。
- 修正: `UX-Music-Watch/Info.plist` に `UIBackgroundModes = [audio]` を
  追加。`WKBackgroundModes` は無害なため削除せず両方を宣言する
  （watchOS のバージョンによる解釈差を吸収する狙い）。
- 検証: `WatchBackgroundAudioInfoPlistTests.swift` に
  `UIBackgroundModes` の存在とその内容を検証するアサーションを追加
  （Red確認後、Info.plist修正でGreen）。さらに `UX-Music-Watch`
  スキームを watchOS Simulator 向けにビルドし、`plutil -p` で
  ビルド済み `Info.plist` に `UIBackgroundModes => ["audio"]` と
  `WKBackgroundModes => ["audio"]` の両方が実際に含まれることを確認。
- 未了: 本追補はビルド成果物レベルの検証のみ。実機での再生継続確認は
  次回実機実行時に行うこと。
