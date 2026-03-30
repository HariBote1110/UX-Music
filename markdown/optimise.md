# 最適化方針と実行計画

## 目的

UX Music の体感品質を落としている要因を、影響度と実装リスクの両面から整理し、着手順と完了条件を固定する。

本計画では以下を主対象とする。

- 再生中の CPU 負荷
- 大規模ライブラリでの UI 応答性
- 長時間利用時の RAM 消費
- Wails 経路の IPC 過多

## 前提

- Single Source of Truth は `markdown/` 配下のドキュメントとする。
- 最適化は必ず「計測 -> 仮説 -> 変更 -> 再計測」で進める。
- 先に局所最適化へ入らず、常時走る処理と常駐メモリから優先する。
- 既存機能の見た目や挙動を崩す変更は、計測効果が大きい場合のみ採用する。

## 優先順位の決め方

優先順位は次の順で判断する。

1. 再生中に常時走る処理か
2. 曲数や歌詞行数に比例して悪化するか
3. Wails の IPC と永続化を頻発させていないか
4. RAM を長時間保持し続ける設計か
5. 低リスクで先に切り出せるか

## 実行順序

### Phase 0: 計測基盤の固定

最初に基準値を取る。計測なしでの最適化は禁止する。

#### Todo

- アイドル時のメモリ使用量を記録する
- ローカル曲再生中の CPU 使用率を記録する
- Wails 再生中の IPC 呼出し頻度を記録する
- 1 万曲規模を想定したスクロール時の体感とフレーム落ちを確認する
- 長い LRC を表示した状態での再生負荷を確認する
- 曲送り時の UI 更新時間を確認する

#### 記録する指標

- アプリ起動直後の RSS
- 5 分再生後の RSS
- 通常再生時の CPU
- ビジュアライザー有効時の CPU
- 曲送り 10 回連続時のメモリ増減
- 再生キュー 1000 件時のキュー描画時間
- 長文歌詞表示時の再生追従遅延

## Phase 1: 低リスク・高効果の即効施策

ここでは設計を大きく崩さず、無駄な更新頻度を落とす。

#### Todo

- 音量スライダーの `input` と設定保存を分離する
- 音量設定保存を `change` または debounce に変更する
- 再生キュー更新で全件再描画をやめ、差分更新に切り替える
- 曲リスト行ごとの個別 `requestAnimationFrame()` をやめ、文字幅判定をバッチ化する
- `window.artworkLoadTimes` を固定長バッファにする

#### 対象箇所

- `src/renderer/js/ui/player-ui.js`
- `src/renderer/js/ui/ui-manager.js`
- `src/renderer/js/ui/element-factory.js`
- `src/renderer/js/ui/utils.js`
- `src/renderer/renderer.js`

#### 完了条件

- 音量ドラッグ中に設定保存が連打されない
- 曲送り時にキュー全体の DOM 再生成が走らない
- 高速スクロール時のレイアウト計測回数が目視で減る

## Phase 2: 再生中ホットパスの最適化

ここでは再生中ずっと走る処理を削る。

#### Todo

- Wails ビジュアライザーの周波数取得を毎フレーム pull しない構造へ変更する
- 周波数データ取得を固定レート化し、描画はキャッシュ参照にする
- Base64 展開の発生頻度を下げる
- 歌詞同期の現在行探索を線形走査から改善する
- 現在行インデックスのキャッシュを導入する
- 歌詞行切替時の DOM 更新対象を全行から局所化する

#### 対象箇所

- `src/renderer/js/features/visualizer.js`
- `src/renderer/js/features/player.js`
- `src/renderer/js/features/lyrics-manager.js`

#### 完了条件

- Wails 再生中の IPC 頻度が明確に減る
- ビジュアライザー有効時の CPU 使用率が改善する
- 長い LRC を表示しても歌詞追従でカクつきにくい

## Phase 3: RAM 消費を下げる構造整理

ここでは長時間保持されるデータ構造を整理する。

#### Todo

- `albums` と `artists` に song object を丸ごと持たず、`song.id` 基準へ寄せる
- `playbackQueue` と `originalQueueSource` の二重配列保持を見直す
- `currentlyViewedSongs` の常駐保持が不要か確認する
- `graphCache` の保持数を 1 件または小さな LRU に制限する
- `MediaSession` 用アートワークを巨大な Data URL ではなく軽量なサムネイルへ寄せる

#### 対象箇所

- `src/renderer/js/core/state.js`
- `src/renderer/js/ui/ui-manager.js`
- `src/renderer/js/features/playback-manager.js`
- `src/renderer/js/features/audio-graph.js`
- `src/renderer/js/features/player.js`

#### 完了条件

- 起動後と長時間再生後の RSS の増え方が緩やかになる
- サンプルレートを跨いだ再生後も不要な AudioContext が残り続けない
- 大規模ライブラリでの常駐メモリが減る

## Phase 4: ライブラリ処理の再設計

ここでは曲数依存で悪化する集計処理を抑える。

#### Todo

- ライブラリ追加時に全アルバム・全アーティストを毎回再構築しない
- 増分更新できる箇所を切り出す
- スキャン完了時の `renderCurrentView()` 全面再描画を必要最小限にする
- ライブラリ更新処理の責務を整理する

#### 対象箇所

- `src/renderer/js/ui/ui-manager.js`
- `src/renderer/renderer.js`
- `src/renderer/js/core/ipc.js`

#### 完了条件

- スキャン中や曲追加時の UI 停止感が減る
- 曲数増加に対する処理時間の伸びが緩やかになる

## 実装方針

### 1. 先に頻度を下げる

処理内容そのものを難しく最適化する前に、まず呼ばれる回数を減らす。

### 2. 次に保持量を減らす

song object の多重保持、Data URL、サンプルレート別キャッシュのように、常駐メモリを増やす構造を優先して削る。

### 3. UI 更新は差分化する

全件 `innerHTML = ''` からの再構築は避け、行単位・要素単位の更新へ寄せる。

### 4. Wails IPC は高コスト前提で扱う

フレーム単位や入力単位の往復は原則禁止とし、イベント化、間引き、バッチ化を前提に設計する。

### 5. 最適化後は必ず逆効果を確認する

CPU が下がっても RAM が増える、RAM が下がっても応答性が落ちる、といった逆効果がないかを確認する。

## 非目標

今回の最適化では、以下は優先対象にしない。

- 見た目の全面改修
- 機能追加を伴う仕様変更
- 再生エンジンの全面置換
- バックエンド言語やフレームワークの変更

## 着手順の結論

最初の着手順は次で固定する。

1. 計測基盤の固定
2. 音量保存頻度とキュー全再描画の停止
3. ビジュアライザーと歌詞同期のホットパス削減
4. RAM 常駐構造の整理
5. ライブラリ更新処理の増分化

---

## 付録: コードレベルの最適化ポイント詳細

以下は 2026-03-31 のコード調査で特定した具体的な最適化候補を、既存の Phase に紐付けて整理したものである。

### A. 再生中ホットパス（Phase 2 関連）

#### A-1. Go バックエンドへのポーリング頻度（影響度: 高）

**場所**: `src/renderer/js/features/player.js` ポーリング処理

200ms 間隔で 4 つの IPC コール（`AudioGetPosition`, `AudioGetDuration`, `AudioIsPlaying`, `AudioIsPaused`）を並列実行している。1 秒あたり 20 回の Wails IPC が発生。

**改善案**:
- 単一の `AudioGetStatus()` エンドポイントに統合し、1 回の IPC で全状態を取得する
- ポーリング間隔を 500ms〜1000ms に延長する
- 歌詞・ビジュアライザーが非表示の場合はさらに間引く

#### A-2. ビジュアライザーの Base64 デコード（影響度: 中）

**場所**: `src/renderer/js/features/visualizer.js` fetchGoData 関数

約 80ms 間隔で Go から Base64 エンコードされた周波数データを取得し、JS 側で `atob()` + ループで `Uint8Array` に変換している。毎フレーム新規配列を確保。

**改善案**:
- `Uint8Array` バッファを事前確保して再利用する
- Go 側でバイナリデータを直接返す方式を検討する
- 描画フレームレートと取得レートを分離し、取得は間引く

#### A-3. プログレスバーの RAF ループ（影響度: 中）

**場所**: `src/renderer/js/ui/player-ui.js` updateProgressBarLoop

`requestAnimationFrame` で毎フレーム（60fps）プログレスバーを更新している。加えて `setInterval` でも別途更新しており、二重更新が発生する可能性がある。

**改善案**:
- `setInterval` を廃止し、RAF のみに統一する
- 実質的な進捗変化がない場合は DOM 書き込みをスキップする

#### A-4. 歌詞同期のスタイル書き込み（影響度: 高）

**場所**: `src/renderer/js/features/lyrics-manager.js` 同期更新処理

全歌詞行に対して 6 つ以上の個別スタイルプロパティ（`transform`, `opacity`, `filter`, `zIndex` 等）を毎回書き込んでいる。`blur()` フィルタは GPU 負荷が高い。

**改善案**:
- 個別 `style` 書き込みの代わりに CSS クラスの付け替えで制御する
- `blur()` フィルタを `opacity` のみに簡素化するか、`will-change` で GPU レイヤーを分離する
- アクティブ行の前後数行のみ更新し、遠い行はスキップする

---

### B. DOM 操作とレンダリング（Phase 1 / Phase 4 関連）

#### B-1. 再生キューの全件再構築（影響度: 高）

**場所**: `src/renderer/js/ui/ui-manager.js` renderQueueView

`innerHTML = ''` で全消去した後、`forEach` + `appendChild` で 1 件ずつ追加。各 `appendChild` でリフローが発生する。さらに各項目に個別のクリックイベントリスナーを登録している。

**改善案**:
- `DocumentFragment` でまとめて構築してから一度に追加する
- イベント委譲（Event Delegation）でリスナーを親要素 1 つにまとめる
- キューにもバーチャルスクロールを適用する（曲リストには `virtual-scroller.js` が既にあるが、キューには未適用）

#### B-2. 再生中インジケーターの DOM 全走査（影響度: 中）

**場所**: `src/renderer/js/ui/ui-manager.js` 再生状態更新処理

`querySelectorAll('.song-item.playing')` で毎回 DOM 全体を走査して現在の再生中要素を探している。

**改善案**: 前回の再生中要素の参照をキャッシュし、直接クラスを付け替える。

#### B-3. ビジュアライザーの DOM クエリ（影響度: 低）

**場所**: `src/renderer/js/features/visualizer.js` setVisualizerTarget

曲切替時に `querySelectorAll('.indicator-ready')` と `querySelectorAll('.playing-indicator-bar')` で DOM を走査。

**改善案**: ターゲット要素とバー配列をキャッシュし、曲切替時にのみ更新する。

---

### C. メモリ構造（Phase 3 関連）

#### C-1. シャッフル時の配列複製（影響度: 中）

**場所**: `src/renderer/js/features/playback-manager.js` シャッフル処理

`filter()` で新規配列を生成した後、Fisher-Yates シャッフルを適用している。大規模キュー（1000 曲以上）でメモリスパイクが発生する。

**改善案**: インプレースシャッフルを使用し、不要な中間配列の生成を避ける。

#### C-2. artworkLoadTimes の splice 操作（影響度: 低）

**場所**: `src/renderer/renderer.js` recordArtworkLoadTime

配列が 200 件を超えると `splice(0, ...)` で先頭を削除。`splice` は O(n) 操作。

**改善案**: リングバッファ（固定長配列 + インデックス）に置き換える。

#### C-3. ライブラリの多重 Map 保持（影響度: 低〜中）

**場所**: `src/renderer/js/core/state.js`

`library`（配列）、`libraryById`（Map）、`libraryByPath`（Map）で同一の Song オブジェクト参照を 3 重に保持。参照のみなのでオブジェクト自体の重複はないが、Map 自体のオーバーヘッドがある。

**現状維持の理由**: O(1) ルックアップのメリットが大きいため、現時点では削減不要。ただし Song オブジェクトにアートワーク Blob が含まれる場合は分離を検討する。

---

### D. イベントリスナー（Phase 1 関連）

#### D-1. リサイズイベントのスロットリング欠如（影響度: 低）

**場所**: `src/renderer/renderer.js` 等

`window.addEventListener('resize', ...)` にスロットルがない。高速リサイズで大量の再計算が走る。

**改善案**: `requestAnimationFrame` または 100ms スロットルでラップする。

#### D-2. ビデオ同期の不可視時実行（影響度: 低）

**場所**: `src/renderer/js/ui/now-playing.js`

250ms 間隔の `setInterval` でサイドバーのビデオ同期を実行しているが、サイドバーが非表示でも停止しない。

**改善案**: サイドバーの表示状態に連動して `setInterval` を開始/停止する。

---

### E. 即効性の高い修正（Quick Wins）

| 項目 | 対象 | 実装難度 | 期待効果 |
|------|------|----------|----------|
| IPC ポーリング間隔の延長 | player.js | 低 | CPU・バッテリー消費削減 |
| 再生中要素のキャッシュ | ui-manager.js | 低 | DOM 走査コスト削減 |
| キュー描画の DocumentFragment 化 | ui-manager.js | 低 | リフロー回数激減 |
| イベント委譲の導入 | ui-manager.js | 低 | クロージャ数削減 |
| blur フィルタの CSS クラス化 | lyrics-manager.js | 低 | GPU 負荷軽減 |
| リサイズのスロットル | renderer.js | 低 | 不要な再計算防止 |
| Uint8Array バッファ再利用 | visualizer.js | 低 | GC 圧力軽減 |

## メモ

- 最初の PR/変更単位は小さく切る
- 各 Phase ごとに再計測結果を `markdown/progress.md` または別タスク文書へ残す
- 体感改善が大きい順に出荷し、後半の構造整理は段階的に行う
- バックエンド（Go）側の最適化は `optimise-backend.md` を参照
