# iOS の音量ノーマライズ修正

## 決定

- 主因はキーではなく値の形式。`server/app_normalize.go` の保存値は旧形式の数値または現行の `{loudness, truePeak}`。`server/app_remote.go` の `/v1/remote/loudness` はパスをライブラリの曲 ID に変換し、値はそのまま返す。iOS の `RemoteAPIClient.fetchLoudness()` が数値だけを採用していたため、現行形式の解析済み曲が全て脱落していた。iOS で両形式を解釈し、HTTP エラーは成功扱いにしない。
- 計算式「目標 LUFS − 曲 LUFS → 線形ゲイン」と既存の最大 4 倍を維持する。ミキサーの `outputVolume` は 0〜1 のため、独立した `AVAudioUnitEQ` の `globalGain` を補正専用に使用する。経路はプレーヤー → グラフィック EQ → 補正 → ミキサー。マスター音量はミキサーだけに適用する。
- 曲・解析値・目標値・有効状態・マスター音量の変更時と、グラフ再接続・エンジン再始動・ルート変更後の再スケジュール時に再適用する。EQ のバイパスやプリセット変更は補正段に影響しない。
- 両方の取得経路（ライブラリ更新／解析値だけの更新）を共通処理に集約し、曲 ID ごとの解析値を保存して起動時に復元する。ダウンロードで変わるのは `Song.path` だけなので、オフラインでも元の `Song.id` で検索できる。デスクトップから消えた曲のダウンロード再生用に既存値を保持し、新しい取得値を優先してマージする。

## 検討した代替案

- Go 側で値を数値に変換する変更は採用しない。既存 API の両形式を iOS が解釈すれば解決し、他クライアントへの影響を避けられる。
- グラフィック EQ のプリアンプに補正値を合算する方式は採用しない。EQ 無効時にも補正を保ち、プリアンプとの合計で上限に達することを避けるため、補正段を独立させる。
- 音声ファイル自体の加工、端末全体の音量変更、解析値からの新しいピークリミッターは追加しない。

## 注意点

- iOS のローカルファイル／ダウンロード済み原音／AAC は同じ `AVAudioEngine` 経路。iOS には独立した `AVPlayer` による LAN ストリーミング再生経路はなく、リモート操作画面の音はデスクトップで再生される。`TVRelayStreamPlayer` と外部再生ブリッジは tvOS 用で、今回の対象外。
- YouTube のストリーミングは `WKWebView` の公式埋め込みであり、ネイティブエンジンを通らない。Google は iOS 埋め込みの動画音量をプログラム制御の例外としている。この経路の音量ノーマライズは今回実装できていない。効かない `setVolume` 呼び出しやシステム音量変更を追加して対応済みとは扱わない。
- 初回の解析値取得前や未解析の曲は等倍。取得後に更新せず音源を差し替えた場合や、異なるサーバーが同じ曲 ID を使った場合、キャッシュ値が古い可能性がある。削除済み曲の値を保持するため、キャッシュは自動削減しない。
- 既存方針どおり `truePeak` はゲイン計算に使用しない。増幅した曲や EQ ブーストの組合せではクリッピングが残り得る。補正用 EQ の最小値は仕様の −96 dB に合わせる。
- 新規 Swift ファイルは追加しない。プロジェクトはファイルシステム同期グループを使っていないため、既存の `RemoteAPIClientTests.swift` に `LoudnessNormalisationTests` を追加した。
- TDD: 本体変更前に現行／旧形式の API 応答を検証する回帰テストを追加。修正前は現行形式の曲が結果から消えるため失敗する。HTTP エラー、両取得経路からのオフライン復元、取得失敗時の保持、増幅・減衰・上限、マスター音量／EQ からの独立性、サンプルレート変更後の接続も検証する。
- 作業環境では変更した Swift ファイルの `swiftc -parse` と `git diff --check` を実施。XCTest はホストで `UX-Music-MobileTests/LoudnessNormalisationTests` と全体を実行する。実機では LUFS が異なる曲の切替、補正の ON/OFF、EQ の切替、Bluetooth 等の出力先変更、機内モードでの再起動後再生を確認する。

参考: [Apple: ミキサー音量の範囲](https://developer.apple.com/documentation/avfaudio/avaudiomixernode/outputvolume)、[Apple: EQ ゲインの範囲](https://developer.apple.com/documentation/avfaudio/avaudiouniteq/globalgain)、[Google: iOS 埋め込みの制約](https://developers.google.com/youtube/data/guides/ios_youtube_helper)。
