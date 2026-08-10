# UX Music Mobile 性能マイクロベンチ ベースライン計測（2026-08）

## 目的 / 仮説

`static-review-2026-08.md` の静的レビューで洗い出した疑い箇所のうち、修正前にコードだけから
再現可能な数値を取れるものをユニットテストの `measure {}` でベースライン計測する。実測は
Instruments ではなく XCTest performance test（simulator）。修正 PR のビフォーアフター比較に
使う出発点であり、絶対性能の主張ではない。

検証する仮説:

1. `DownloadManager.isDownloaded` は 1 回の呼び出しごとに `tracksDirectory` を全列挙するため、
   n 件の行を持つ画面を 1 回描画するコスト（n 回呼び出し）は n に対して **二次（O(n²)）** で伸びる。
2. ライブラリ画面の 1 キーストロークあたりの再計算（ソート＋検索＋アルバム/アーティストのグループ化、
   非表示タブ含む）は 800 曲規模でも UI が引っかかるほどではない範囲に収まる（か否か）。
3. `DownloadManager` の init（`loadMeta`）は n=800 のダウンロード済みライブラリで起動時間に
   無視できないコストを持つ。
4. アートワークはサムネイルデコード（`CGImageSourceCreateThumbnailAtIndex` + maxPixelSize）の方が
   フル解像度デコード（`UIImage(contentsOfFile:)`）より明確に速い。

## 環境

- ホスト: この Mac（Apple M4, Mac16,10）, macOS 26.5.2 (Darwin 25.5.0)
- Xcode 26.5 (17F42) / xcodebuild
- 実行先: iPhone 17 シミュレータ（iOS 27.0）
- ブランチ: `ai-feature-special`
- **注意**: シミュレータ計測値は実機の絶対性能を表さない。ここでの数値は
  「スケーリングの形」と「修正前後の比較」のためのものであり、実機の体感値ではない。

## 手順

### 1. ベンチマークテストファイル

`UX-Music-Mobile/UX-Music-MobileTests/PerformanceBenchmarkTests.swift`。全テストの先頭で

```swift
try XCTSkipUnless(ProcessInfo.processInfo.environment["UXM_PERF"] == "1", "Set UXM_PERF=1 to run performance benchmarks")
```

によりゲートされ、`UXM_PERF=1` が立っていない限り通常スイートではスキップされる。

`xcodebuild test` は `TEST_RUNNER_` 接頭辞の環境変数だけをテストプロセスへ転送する。これを
実機（シミュレータ）で経験的に確認済み: `TEST_RUNNER_UXM_PERF=1` を渡すとテストは実行され
（1.4秒、`measure` 込み）、渡さないと `skipped (0.012 seconds)` で即終了することを個別テスト
1件で確認した。

### 2. 実行コマンド（再現用）

```bash
cd UX-Music-Mobile
# ベンチマークのみ実行（ビルド込み）
TEST_RUNNER_UXM_PERF=1 xcodebuild test \
  -scheme UX-Music-Mobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:UX-Music-MobileTests/PerformanceBenchmarkTests

# 通常スイート（ゲートなし＝ベンチマークはスキップされる）
xcodebuild -scheme UX-Music-Mobile \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

数値（平均・標準偏差・相対標準偏差）は `.xcresult` から
`xcrun xcresulttool get test-results metrics --path <xcresult>` で取得した
`measurements`（`measure {}` の 10 回試行の生データ、秒単位）を Python で集計した
（`statistics.mean` / `statistics.stdev`、n=10）。

## 結果

### (a) `DownloadManager.isDownloaded` の n スケーリング

n 件の曲を事前にダウンロード登録した状態で、n 件全曲について `isDownloaded(songId:)` を
1 回ずつ呼ぶコスト（= n 行の画面を 1 回描画した場合の合計コスト相当）。

| n | 平均 | 中央値 | 標準偏差 | 相対標準偏差 |
|---|---|---|---|---|
| 100 | 97.81 ms | 101.91 ms | 13.14 ms | 13.4% |
| 400 | 1258.05 ms | 1125.92 ms | 341.15 ms | 27.1% |
| 800 | 5219.87 ms | 5108.66 ms | 1084.98 ms | 20.8% |

スケーリング比（平均値ベース）:

| 区間 | n の倍率 | 所要時間の倍率 | 線形なら | 二次(O(n²))なら |
|---|---|---|---|---|
| 100→400 | 4.0x | **12.86x** | 4.0x | 16.0x |
| 400→800 | 2.0x | **4.15x** | 2.0x | 4.0x |
| 100→800 | 8.0x | **53.4x** | 8.0x | 64.0x |

### (b) ライブラリ画面 1 キーストロークあたりの再計算コスト

800 曲（アルバム40 × 20曲、アーティスト25種）の合成ライブラリに対し、
`LocalLibraryScreen` の `sortedSongs`/`searchedSongs`/`searchedAlbums`/`searchedArtists`
（非表示タブ含む全4系統）を1回分再計算するコスト。

| 平均 | 中央値 | 標準偏差 | 相対標準偏差 |
|---|---|---|---|
| 32.72 ms | 32.70 ms | 4.50 ms | 13.8% |

### (c) `DownloadManager` init（`loadMeta`）の起動コスト

n=800 のダウンロード済みフィクスチャ（ファイル＋UserDefaultsのメタ情報）が既にある状態で、
新規に `DownloadManager()` を構築するコスト。

| 平均 | 中央値 | 標準偏差 | 相対標準偏差 |
|---|---|---|---|
| 183.18 ms | 179.13 ms | 6.23 ms | 3.4% |

### (d) アートワークのフル解像度デコード vs ダウンサンプルデコード

合成3000×3000 JPEG（グラデーション、`UIGraphicsImageRenderer` 生成、品質0.9）に対し、
(i) `RemoteArtworkCaching` 現行パターン（`UIImage(contentsOfFile:)` フル解像度デコード）と
(ii) `ArtworkPaletteExtractor` の良パターン（`CGImageSourceCreateThumbnailAtIndex`,
`kCGImageSourceThumbnailMaxPixelSize: 96`）を比較。両者ともデコード後に 1×1 ビットマップへ
描画して遅延デコードを強制。

| 方式 | 平均 | 中央値 | 標準偏差 | 相対標準偏差 |
|---|---|---|---|---|
| (i) フル解像度 (`UIImage(contentsOfFile:)`) | 57.20 ms | 57.20 ms | 7.46 ms | 13.0% |
| (ii) 96px サムネイル (`CGImageSourceCreateThumbnailAtIndex`) | 62.19 ms | 55.45 ms | 17.94 ms | 28.8% |

(ii) の生データ10回のうち1回目が 111.18 ms の外れ値（デコーダプラグインのウォームアップと
推測）で、それを除いた9回の平均は 56.74 ms（フル解像度の 57.20 ms とほぼ同値）。

### (e) 通常スイートの健全性確認

`UXM_PERF` 未設定でフルスイートを実行: 443 件 pass + 1 件 pre-existing の実機限定スキップ
（`LANDiscoveryPeerTests.testRealDeviceDiscoversUXSyncMDNSPeer`、simulator では常時スキップ）
＝既存ベースラインの444件と一致。新規追加した `PerformanceBenchmarkTests` の7件は全て
`skipped` （ゲートが機能）。`** TEST SUCCEEDED **`。

## 結論

- **仮説1（isDownloadedの二次スケーリング）: 採用。** 100→400 で12.86倍、400→800 で4.15倍と、
  線形（それぞれ4.0倍・2.0倍）よりも二次スケーリング（それぞれ16.0倍・4.0倍）に近い伸び方をした。
  静的レビューの「呼ぶたびに全列挙するので O(n²)」という指摘は実測でも支持される。
  n=800 で1描画パスあたり平均5.2秒は、実機でもリスト描画のカクつきとして体感される規模感。
- **仮説2（キーストローク再計算コスト）: 800曲規模では単発では軽い（平均33ms）。** ただし
  デバウンスなしで毎タイプ即時実行される点、DownloadManagerのisDownloadedコストとは独立して
  積み上がる点は静的レビュー通りで、「単発では軽いが、他の重い処理（1・3・5）と重なると
  体感に効く」という見立てを補強する数値。単体では最優先の修正対象ではなさそうという弱い
  反証材料も兼ねる（が、これだけでは棄却とまでは言えない — 実機・低スペック機での検証は未了）。
- **仮説3（DownloadManager init コスト）: 800曲で平均183ms、相対標準偏差3.4%と安定して重い。**
  起動経路（`AppModel.init`）に同期で乗るため、n が伸びるほど起動体感に直結する。静的レビューの
  指摘通り、非同期化の価値がある規模のコスト。
- **仮説4（サムネイルデコードの優位性）: このシミュレータ・この合成画像では棄却（有意差なし）。**
  ウォームアップ外れ値を除いても両者はほぼ同値（56.74ms vs 57.20ms）。理由の推測: グラデーション
  JPEGはDCT係数のエントロピーが低く圧縮後サイズが小さいため、フルデコードのコストそのものが
  低く、ダウンサンプルによる短縮効果が相対的に見えにくい可能性が高い。写真的な複雑な画像や
  実際のジャケット画像での再検証、および実機（またはInstruments Time Profiler）での確認が
  必要 — この結果だけで「4番は対策不要」と判断するのは早計。

## 次の一手 / 未検証事項

- (d) は合成グラデーション画像の限界が疑われるため、実際のジャケット画像（JPEG, 3000px級,
  高周波成分あり）でのA/Bを別途取ってから4番の対策要否を最終判断する。
- 修正実装（1番: stem辞書化によるisDownloadedのO(1)化）を先に着手し、本ノートの(a)表を
  ビフォーアフター比較のベースラインとして使う。
- (c) DownloadManager initの非同期化後、同条件でこのベンチを再実行し改善幅を確認する。
- (b) は800曲規模の単発コストは軽いが、デバウンスや非表示タブの遅延評価を入れた場合の
  改善幅も後続で計測する価値がある（現状は「対策前でも軽い」という参考値）。
