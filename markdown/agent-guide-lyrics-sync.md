# AI エージェント向け：歌詞自動同期のテストと調整

このドキュメントは、**自動歌詞同期パイプライン**（Python サイドカー `python/lyrics_sync/`）の検証・ベンチマーク・パラメータ調整を扱うエージェント向けの単一参照です。処理仕様の概要は別ドキュメント（例：`lyrics-sync-plan.md` があればそれ）を参照してください。

---

## 1. TL;DR（エージェントが最初に読むべきこと）

| 項目 | 内容 |
|:---|:---|
| 目的 | Demucs → Whisper → 整列（`stage3_align`）による **行ごとの開始時刻** を、`IGNORE/` のゴールデン参照と比較して改善する |
| ゴールデン（アムネシア） | `IGNORE/アムネシア/lyrics.txt` と **`manualversion.lrc`**（旧タイポ名 `manualverison.lrc` もフォールバックで読む）が **36 行そろって対応**していることを前提にベンチマークする |
| 軽量テスト | `cd python && .venv/bin/python -m pytest tests/ -m "not heavy"`（GPU・長時間 ASR なし） |
| 重い結合テスト | **`UX_MUSIC_IGNORE_INTEGRATION=1`** を付けたときのみ実行。実 FLAC とモデルを使う |
| 調整ループ | **行別ずれ表**を見る → **ノブを 1 つだけ変える** → 同じコマンドで再計測 → JSON で差分比較 |

---

## 2. ディレクトリとファイルの前提

### 2.1 `IGNORE/`（Git にコミットしない）

`.gitignore` に含まれる。**ユーザー環境ローカルのみ**。エージェントはパスだけ把握し、リポジトリにファイルを追加しないこと。

アムネシア標準構成の例：

```text
IGNORE/アムネシア/
  *.flac              … 音声（先頭をテストが使用）
  lyrics.txt          … 入力歌詞（空行は読み飛ばし）
  manualversion.lrc   … 手動調整の参照タイムスタンプ（優先）
  manualverison.lrc   … 旧タイポ名（無ければ無視）
```

### 2.2 Python テストコード（リポジトリに追跡）

| パス | 役割 |
|:---|:---|
| `python/tests/sync_accuracy.py` | MAE／許容差し引き後 MAE／**行別ずれ行**／誤差帯バケツ |
| `python/tests/lrc_reference.py` | 参照 LRC のパース、`lyrics.txt` と **テキスト行ごと一致**検証 |
| `python/tests/amnesia_manual_assets.py` | `manualversion.lrc` を優先して解決 |
| `python/tests/test_ignore_amnesia_manual_reference.py` | アムネシア結合ベンチと **標準出力レポート** |
| `python/tests/test_stage3_interpolate.py` | `_interpolate_rows` の単体試験 |
| `python/tests/conftest.py` | `python/` を `sys.path` に追加 |

### 2.3 実装側の調整ノブ（`python/lyrics_sync/stage3_align.py`）

- **単調マッチ**：埋め込みコサインと文字バイグラムの合成重み **`UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT`**（既定 `0.52`、残りはバイグラム）
- **補間ステップ**：**`UX_MUSIC_SYNC_INTERPOLATE_STEP_SECONDS`**（既定 `2.5`）
- **大ジャンプ修復**：**`UX_MUSIC_SYNC_MAX_LINE_GAP_SECONDS`**（既定 `42`）、**`UX_MUSIC_SYNC_REPAIR_JUMP_MIN_BIGRAM`**（既定 `0.22`）

---

## 3. 環境変数一覧（同期テスト・調整）

「未設定」の挙動はコード側の既定値に従う。

### 3.1 結合試験のゲート

| 変数 | 値 | 意味 |
|:---|:---|:---|
| `UX_MUSIC_IGNORE_INTEGRATION` | `1` / `true` / `yes` | **これだけ**指定すると heavy 結合試験が動く（CI で誤実行しないための明示オプトイン） |

### 3.2 Whisper・ダミー

| 変数 | 既定 | 意味 |
|:---|:---|:---|
| `UX_MUSIC_IGNORE_TEST_WHISPER_MODEL` | （実装依存、`base` 想定） | 結合試験でのモデル名 |
| `UX_MUSIC_LYRICS_SYNC_DUMMY` | 未設定 | `1` のときダミーパイプライン（結合検証には不向き） |

### 3.3 手動参照との比較（許容・メトリクス）

| 変数 | 既定 | 意味 |
|:---|:---|:---|
| `UX_MUSIC_SYNC_MANUAL_TOLERANCE_SECONDS` | `0.5` | 手動 LRC は Bluetooth 調整などで **±500ms 程度のブレ**を前提に、`timing_mae_after_tolerance_seconds` を解釈する |
| `UX_MUSIC_SYNC_REPORT_TOP_N` | `15` | 行別ずれ表に出す **上位 N 行**（`\|Δ\|` 降順） |
| `UX_MUSIC_SYNC_REPORT_JSON` | 空 | パスを指定すると `{ metrics, buckets, per_line, env_snapshot }` を JSON で保存 |

### 3.4 アサート（任意）

| 変数 | 意味 |
|:---|:---|
| `UX_MUSIC_SYNC_ASSERT_MAX_MAE_SECONDS` | 素の MAE 上限（設定時のみアサート） |
| `UX_MUSIC_SYNC_ASSERT_MAX_MAE_AFTER_TOLERANCE_SECONDS` | 許容差し引き後 MAE の上限 |

---

## 4. エージェント向け作業フロー（改善サイクル）

### 4.1 軽量検証（依存・パス確認）

```bash
cd python
.venv/bin/python -m pytest tests/ -m "not heavy" -v
```

- アセットが無い環境では、アムネシアの **ペアリング試験以外**は skip または実質スキップされうる。**ローカルで IGNORE が揃っているか**はユーザーに確認してよい。

### 4.2 ずれを「見える化」する（重い）

リポジトリルートから：

```bash
chmod +x scripts/report-amnesia-sync-delta.sh
./scripts/report-amnesia-sync-delta.sh
```

または：

```bash
cd python
UX_MUSIC_IGNORE_INTEGRATION=1 \
  .venv/bin/python -m pytest \
  tests/test_ignore_amnesia_manual_reference.py::test_amnesia_auto_sync_vs_manual_lrc_metrics \
  -v -s --tb=short
```

標準出力に以下が出る：

1. **集約メトリクス**（`MAE(raw)`、`MAE(after_tol)` など）
2. **誤差帯バケツ**（例：`abs_delta_ge_90s`）
3. **行別表**：`|Δ|` が大きい順、**符号付きΔ**（予測が参照より遅い `+`／早い `-`）、`source`

### 4.3 改善の進め方（ルール）

1. **一度に変えるのは 1 ノブだけ**（例：`UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT` を `0.48` にする）。
2. 同じ結合コマンドを再実行する。
3. `UX_MUSIC_SYNC_REPORT_JSON` で **変更前／変更後**をファイルに保存し、`metrics` と `per_line` を diff する。
4. 回帰が出たらノブを戻すか、別ノブと組み合わせる（組み合わせは **記録が取れた状態**でのみ）。

### 4.4 報告するときに書くべき項目（ユーザー向けサマリー）

- 使用した **`UX_MUSIC_IGNORE_TEST_WHISPER_MODEL`**
- **`MAE(raw)` / `MAE(after_tol)`** と **`within_tol` の割合**
- **上位ずれ表に現れた歌詞の傾向**（繰り返しコーラス／楽曲前半のみ狂う等）
- 変更した環境変数の一覧と、その意図（一文）

---

## 5. メトリクスの読み方（エージェント向けヒント）

| 現象 | 読み取りのヒント |
|:---|:---|
| `符号付Δ` が **大量に正**（予測が遅い） | Whisper セグメントや単調整列が **楽曲後ろへドリフト**している可能性。埋め込み／バイグラム比 **`UX_MUSIC_SYNC_MONOTONE_EMBED_WEIGHT`**、またはジャンプ修復 **`UX_MUSIC_SYNC_MAX_LINE_GAP_SECONDS`** を検討 |
| **ごく一部の行だけ** `\|Δ\|` が巨大 | **同一フレーズの繰り返し**で別セグメントへ結合されている可能性。修復やバイグラム比率の調整・将来的には重複行の特別扱いなど |
| `match` は高いが MAE が悪い | **時刻はセグメント／語レベルで付いているが、参照との絶対位置がずれている**。モデルサイズや Demucs／音声との関係を別タスクで切り分ける |

---

## 6. フロントエンド（再生側）との関係（参照のみ）

歌詞 JSON／LRC を読み込む処理では、**同一タイムスタンプが連続する行**があると二分探索の挙動が破綻しやすい。**パース後に時刻を微小ステップだけ単調増加させる**対策が renderer にある（詳細は `src/renderer/js/features/lyrics-translation.ts` の `parseLRC`）。  
パイプライン調整とは別レイヤーの話だが、「再生だけおかしい」ときはここも疑う。

---

## 7. よくあるミス（エージェント向け）

- **`IGNORE/` にファイルをコミットしようとする** … 禁止。ドキュメント・テストだけ更新する。
- **heavy を CI で無条件実行する** … `UX_MUSIC_IGNORE_INTEGRATION` 無しでは skip させる設計を崩さない。
- **手動 LRC を絶対真理として閉じる** … `UX_MUSIC_SYNC_MANUAL_TOLERANCE_SECONDS` を無視せず、`MAE(after_tol)` を主指標にする。
- **`manualversion.lrc` と `lyrics.txt` の行数・順序がずれたままベンチマークする** … `reference_times_for_lyrics_txt` が例外を投げる。先にペアリング試験を通す。

---

## 8. 関連コマンド（開発環境）

| コマンド | 説明 |
|:---|:---|
| `make lyrics-sync-python` | （Makefile がある場合）Python venv と依存のセットアップスクリプト実行 |

仮想環境は **`python/.venv`** を前提とする。`pytest` は **`cd python`** してから実行する。

---

以上を、歌詞同期まわりを触るエージェントの **入口ドキュメント**として利用してください。実装変更時は **`tests/` を Single Source of Truth** にし、期待どおり動くようにテストを先に更新してから本体を直す運用を推奨します。
