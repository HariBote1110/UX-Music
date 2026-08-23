# まとめ・抜本策の優先順位

## 目的

`02`・`03`の結果を踏まえ、Remote関連タブの「重さ」の原因を測定値に基づいて
優先順位付けし、`/development`フローで再実装すべき修正のスペックを示す。

## 仮説の採否まとめ

| 仮説 | 採否 | 根拠 |
|---|---|---|
| H1: ポーラーが無条件書き込みでRemoteタブ全体を毎tick再評価させている | **部分採択**（Controlタブのみ） | `02`の実測: Controlタブアイドル時CPU中央値1.0%・p95 2.7%（Remote(Library)タブは0.3%/0.6%）。原因は`RemoteControlScreen.pollOnce()`の`desktopState: [String: Any]`無条件代入。`AppModel.sidecarPollOnce()`は既に差分ガード済みで無関係。 |
| H1（Remote Libraryタブ全体への波及） | 棄却 | 同上。`RemoteLibraryScreen`自体はポーラーを持たない。 |
| H2: アートワークの再フェッチ・再デコード | **部分採択**（デコードのみ） | `03`: `task(id:)`安定・actor集約により二重フェッチ/再フェッチは無し（棄却）。ただし小タイルでもフル解像度デコード（ダウンサンプリング不使用）は実装上の事実（採択、影響度は未計測）。 |
| H3: グリッドの不安定IDによる行再生成 | 棄却 | `03`: Albums/Songsは安定ID。Playlistsのみ`id: \.offset`だが更新頻度が低く実害なし。 |
| H4: LazyTabRootの多重保持によるコスト倍加 | **限定的に採択** | `02`の計測はControlタブ訪問後もRemote(Library)タブに戻った状態（H4の実条件）で行ったが、Remote(Library)タブのCPUはControlタブ単独の1/3程度に留まった。つまりH4自体が支配的要因ではなく、「H1で重いタブ（Control）を一度訪問すると、以後どのタブにいてもその重さが裏で回り続ける」という**乗数効果**としてのみ寄与する。 |

## 優先順位付け（測定された影響度順）

1. **最優先: `RemoteControlScreen.pollOnce()`の`desktopState`書き込みに差分ガードを入れる**
   実測でアイドルCPU中央値を3倍・p95を4.5倍に押し上げている、唯一定量化できた
   支配的要因。`AppModel.sidecarPollOnce()`が`SidecarMetadataSnapshot`で行った
   のと同じパターンをControlタブにも適用する。

   **再実装スペック（案）**:
   - `RemoteControlScreen`に`RemoteControlStateSnapshot: Equatable`
     （`title`/`artist`/`album`/`songId`/`duration`/`playing`など、シークバー
     が読む`position`は毎tick更新が必要なので対象外）を追加。
   - `pollOnce()`は`fetchState()`の結果からsnapshotを組み、直前の値と比較して
     差分がある時だけ`desktopState`（または新設のプロパティ群）を書き換える。
   - `position`相当のみ`SidecarProgressInterpolation`と同様に毎tick更新可。
   - TDD: `RemoteControlStateSnapshotTests`（Equatable判定の単体テスト）→
     `pollOnce()`の書き込みガード実装。

2. **次点: `ArtworkImageView`/`WearCachedHeroArtworkView`のデコードにダウン
   サンプリングを導入する**
   実害の定量化はできていないが、実装上フルサイズデコードが確認できており、
   500曲規模のグリッドをスクロールする使い方（ユーザー報告の「全体的に重い」に
   最も近いシナリオ）でCPU/一時メモリコストに効く可能性が高い。

   **再実装スペック（案）**:
   - `wearRemoteArtworkLoadDirect`のデコード箇所（ファイル読み込み・HTTP
     レスポンス両方）を`UIImage(data:)`/`UIImage(contentsOfFile:)`から
     `UIImage.preparingThumbnail(of:)`（表示`size`から算出したCGSizeを渡す）
     に置き換える。ヒーロー画像（`WearCachedHeroArtworkView`、`height`基準）と
     グリッドタイル（`size`基準）で目標サイズが異なる点に注意。
   - 計測: `03`の「次の一手」に挙げた通り、実装前後でグリッド連続スクロール時の
     CPU/RSSをA/B比較してから確定させる。

3. **低優先: Playlistsグリッドの`id: \.offset`を安定キーに直す**
   現状の更新契機では実害が無いため、着手は他の作業のついでで良い。

## LazyTabRootの多重保持（H4）について

`LazyTabRoot`（`Views/HomeRootView.swift`）は一度訪問したタブを`opacity(0)`で
裏に残す設計そのものは、`mobile-ux-fixes-2026-08.md`3項の「初回訪問時の
Push遷移崩れ」を直すための意図的なトレードオフであり、それ自体を後退させる
必要はない。今回の実測が示すのは「個々のタブが自分自身のアイドルコストを
0に近づけていれば、裏で複数タブが生き続けても合計コストは低く保てる」という
ことなので、**優先度1のControlタブ修正が最も費用対効果が高い**という結論を
補強する形になった。

## 確認事項

- 作業ツリーは`mobile_remote_perf_research/`以外に変更なし（`git status
  --porcelain`で確認済み）。アプリ本体・テストへの一時計装コードは今回は
  導入しなかった（静的解析と`ps`ベースの外部計測のみで十分な精度が得られたため）。
- 本タスクでは修正は実装していない。上記1・2は`/development`フロー
  （TDD・意思決定ログ）で別途着手すること。
