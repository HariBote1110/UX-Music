# Apple Watch の音声出力設定

## Decision

- `WatchAudioOutputPreference` に `automatic`、`bluetooth`、`speaker` の3モードを追加し、`UserDefaults` の `watchAudioOutputPreference` に保存する。未保存時は `automatic` とする。
- `speaker` は plain `.playback` / `.default` のみ、`bluetooth` は `.longFormAudio` のみを試行する。`automatic` は接続済みBluetooth出力を検出した場合だけ long-form を先に試し、失敗時にスピーカーへフォールバックする。検出できない場合はスピーカーへ直行し、システムの出力先ピッカーを出さない。
- Bluetooth検出は `currentRoute.outputs` と、watchOSで利用できる場合の `availableInputs` の port type を見る小さなヒューリスティックに隔離した。実機での判定精度は未検証のため、`bluetoothDetection` ログで確認できるようにする。
- 出力設定の変更中は再生状態を記憶して一時停止し、セッションを非アクティブ化してから新しい設定で再アクティベートし、変更前に再生中だった場合だけ再開する。

## Alternatives considered

- long-form のアクティベート失敗後に常にスピーカーへフォールバックする方式は、Bluetooth未接続時にもシステムの出力先ピッカーを先に表示するため採用しない。

## Constraints / Gotchas

- `isSpeakerFallback` は名前に反してフォールバック時だけでなく、ユーザーが `speaker` を明示選択した場合も plain speaker セッション中は `true` とする。
- `WatchAudioActivationPolicy` は、以前のアクティベーションポリシーが現在の設定・検出結果と一致する場合だけ再アクティベートを省略する。設定変更時は `activatedPolicy` を消去して必ず新しい計画を評価する。
- watchOS 26.5 SDKヘッダー上、`availableInputs` / `currentRoute` / `setActive` は watchOS 2.0、long-form の非同期 `activate` は watchOS 5.0 から利用可能。実機でのスピーカー再生継続とBluetooth検出結果は親ブランチで確認する。
- watchOSでは、route-sharing policyがなくても `activate(options:)` がシステムの「Bluetoothデバイスを選択」ルートピッカーを表示する。（2026-09-13 実機ログで確認: speaker 経路が `activated=false error=nil` を返しピッカー表示）。初期版 Watch（`1e4e6cb7^`）は `setCategory(.playback)` ＋同期 `setActive(true)` でスピーカー再生できていたため、スピーカー経路は同期 `setActive(true)` に戻した（修正後の実機確認は未了）。
