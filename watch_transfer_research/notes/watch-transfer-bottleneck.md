# iPhone→Watch 転送が遅い問題のボトルネック調査

## 目的 / 仮説

実機報告「iPhone から Apple Watch への楽曲転送が遅い」の原因を特定する。

仮説: **転送しているファイルが原本（FLAC 中心・平均 30MB 超）であることが支配的要因**。
WatchConnectivity（`WCSession.transferFile`）の実効帯域は OS 管理で変更不可（Bluetooth 経由で実効 50〜100 KB/s 程度、Wi-Fi 併用時でも数百 KB/s）なので、ユーザ側で制御できる変数はほぼ「ファイルサイズ」のみ。仮説が正しければ、AAC 128 kbps へのトランスコードでサイズ削減率ぶんだけ転送時間が短縮される。

反証条件: ライブラリの大半が既に小さい圧縮音源（MP3/AAC ≤192kbps）なら、トランスコードしても削減率は 1〜1.5 倍程度に留まり、この最適化は棄却。

## 環境

- ホスト: ユーザの Mac（Darwin 25.5.0）、デスクトップ UX Music のユーザデータ `~/Library/Application Support/UX-Music`
- ライブラリ: `library.json` 記載の 799 曲（全て実在）
- 測定: `tools/measure_library_reduction.py`（afinfo で duration 取得、AAC128 サイズは duration×128kbps×1.04 で推定）
- サンプル: seed=42 で 40 曲無作為抽出

## 手順

```bash
python3 watch_transfer_research/tools/measure_library_reduction.py 40
```

## 結果

ライブラリ構成: **FLAC 700 曲（88%）** / MP3 90 / m4a 5 / WAV 4。

| 指標 | 値 |
|---|---|
| 平均原本サイズ | 30.3 MB（中央値 33.3 MB） |
| 平均 AAC128 サイズ（推定） | 4.1 MB |
| 集計削減率 | **7.3x** |
| FLAC のみ (n=34) | 平均 34.7 MB → 削減 **8.4x** |
| MP3 のみ (n=6) | 平均 4.9 MB → 削減 1.2x |

転送時間の見積もり（BT 実効 60 KB/s と仮定）: FLAC 1 曲 34.7 MB ≈ **約 10 分** → AAC128 4.1 MB ≈ **約 70 秒**。

## 現状実装の確認（コードリーディング）

- iPhone のダウンロードは常に原本: `AppModel.swift:431` が `preferOriginalAudio: true` で `/v1/remote/file?...&source=original` を取得。
- Watch 転送はその原本をそのまま送信: `WatchTransferBridge.performTransfer` が `downloadManager.localPathString` の URL を `session.transferFile` に直接渡す。
- アートワークは既に最適化済み（長辺 400px・JPEG q0.6・別 transferFile）。ボトルネックではない。
- デスクトップサーバには既に Watch 向けトランスコードが存在: `server/app_remote.go` `getOrTranscode`（ffmpeg AAC 128k / 44.1kHz / stereo / `-vn` / `-map_metadata 0`、`RemoteCache/<sha256>.m4a` にキャッシュ）。ただし iPhone 側は `source=original` 固定なので現在未使用経路。
- Watch 側再生は `AVPlayer`（`WatchAudioPlayerService`）なので AAC/m4a は追加実装なしで再生可能。

## 結論

**仮説は採択**。ライブラリの 88% が FLAC で、AAC 128 kbps 化により転送バイト数を約 7〜8 分の 1 にできる。WCSession の帯域は制御不能なため、サイズ削減が唯一かつ最大の最適化。

MP3（≒既に ≤320kbps）は削減 1.2x しかなく、再エンコードは品質劣化と CPU 時間に見合わない → **既圧縮・低ビットレート音源はパススルー**にすべき。

### 実装方式の選定

iPhone **オンデバイストランスコード**（AVAssetReader/Writer, AAC 128kbps m4a）を採択。

- 代替案「サーバの transcoded 変種を Watch 用に別途ダウンロード」は棄却: デスクトップ接続が必須になり（オフライン時に転送不可）、DownloadManager が 1 曲 2 変種を管理する複雑さが増す。オンデバイス変換ならダウンロード済み曲はいつでも転送可能。
- iPhone の AAC エンコードは実時間の数十倍速（4 分曲で数秒）で、10 分→70 秒の転送短縮に対し無視できるコスト。

### 実装方針（/development へ引き継ぎ）

1. 送信判定の純ロジック: fileType と推定ビットレート（size×8/duration）から transcode / passthrough を決定。FLAC/WAV/AIFF は常に transcode。MP3/AAC/m4a は推定ビットレート >192kbps のときのみ transcode。duration 不明時は非可逆形式ならパススルー（安全側）。
2. トランスコーダ: AAC-LC 128kbps / 44.1kHz / stereo の m4a を Caches 配下に書き出し、決定的ファイル名でキャッシュ（再送時に再変換しない）。
3. `performTransfer` で変換後 URL を `transferFile` に渡す。メタデータ `fileType` は "m4a" に更新。変換失敗時は原本送信にフォールバック。

## 次の一手 / 未検証事項

- WCSession の実効スループット実測値（実機 iPhone⇔Watch でのみ測定可能。転送時間ログを仕込めば実機報告から回収できる）。
- Watch アプリをフォアグラウンドにすると WCSession 転送が優先される（既知の挙動）。UI ヒントとして出す価値はあるが未定量。
- 実機での AAC128 変換所要時間の実測（見積もりのみ）。
