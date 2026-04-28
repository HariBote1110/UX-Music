# 歌詞自動同期（Python サイドカー）のテスト

自動歌詞同期パイプライン（`python/lyrics_sync/`）と、ローカル検証用アセット（`IGNORE/`）まわりのテスト実行手順をまとめる。処理仕様自体は [`lyrics-sync-plan.md`](./lyrics-sync-plan.md) を参照。

---

## 1. 構成の概要

| 項目 | 内容 |
|:---|:---|
| テストルート | リポジトリ直下の **`python/tests/`**（`pytest` は **`python/`** をカレントにして実行する想定） |
| import 経路 | `python/tests/conftest.py` が `sys.path` に **`python/`** を追加し、`lyrics_sync` を import 可能にしている |
| マーカー | `heavy` は **Demucs、faster-whisper、埋め込みモデル**など重い処理を伴う結合テスト用（`pytest` で個別選択可能） |

---

## 2. クイックスタート（軽量テストのみ）

依存は **`python/pyproject.toml`** の開発用オプション（`pytest` 等）および歌詞同期用ランタイム（`pip install -e '.[dev]'` などローカルの手順に従う）を満たすこと。

リポジトリルートから:

```bash
make test-lyrics-sync
```

等価コマンド:

```bash
cd python && python3 -m pytest tests/ -m "not heavy" -v
```

**`heavy`** マーカ付きテストは上記では **収集のみ除外**される（または deselect される）。結合パイプラインは別途実行する（次節）。

---

## 3. 重い結合テスト（`IGNORE/` + E2E）

### 3.1 目的

`IGNORE/` に **`lyrics.txt`** と **`*.flac`**（ユーザーが用意した音声）があるときのみ、実際に **`run_pipeline`**（分離→ASR→整列）を走らせる。

### 3.2 レイアウトの例

- `IGNORE/lyrics.txt` … UTF-8。空行のみの行はテスト側で読み飛ばし、**非空行だけ**リクエストの `lines` に詰める。
- `IGNORE/*.flac` … **`*.flac` / `*.FLAC`** を名前順で並べ、**先頭の 1 ファイル**だけを音声パスとして使う（例: `04 - アムネシア.flac`）。

`/IGNORE` は **`.gitignore` に含まれる**。アセットはリポジトリにコミットされず、**各開発者マシンのローカル専用**とする。

### 3.3 実行条件と環境変数

結合テストは **`UX_MUSIC_IGNORE_INTEGRATION=1`** のときのみ実行される（実行せず明示的スキップする）。意図は **誤って CI で重い処理を動かさないこと** と **ローカルでの明示オプトイン**。

| 変数 | 意味 |
|:---|:---|
| `UX_MUSIC_IGNORE_INTEGRATION` | `1` / `true` / `yes` のときのみ `heavy` のフルパイプライン試験が走る |

任意:

| 変数 | 意味 |
|:---|:---|
| `UX_MUSIC_IGNORE_TEST_WHISPER_MODEL` | 結合テスト内での Whisper モデル名（未設定時は `base` 相当の既定がある：実装側の **`test_ignore_pipeline_integration.py`** の説明どおり）。短時間での煙のみなら **`base`** など軽めの指定を検討。 |

Makefile から実行する場合:

```bash
export UX_MUSIC_IGNORE_INTEGRATION=1
# （任意）
export UX_MUSIC_IGNORE_TEST_WHISPER_MODEL=base

make test-lyrics-sync-ignore-e2e
```

手動での等価例:

```bash
cd python && UX_MUSIC_IGNORE_INTEGRATION=1 python3 -m pytest tests/test_ignore_pipeline_integration.py -m heavy -v --tb=short
```

**時間・ディスク・CPU/GPU に余裕がある環境のみ**実行すること。**初回**はモデル取得や ONNX 類のキャッシュによりさらに時間がかかる。

---

## 4. テストファイルの対応ざっくり表

| ファイル | 内容 |
|:---|:---|
| `conftest.py` | `python/` をパスに追加 |
| `ignore_assets.py` | リポジトリルート基準で `IGNORE/` のパス・歌詞読み込み・結合フラグ判定 |
| `test_ignore_local_assets.py` | `lyrics.txt` / FLAC が存在するときのみ走る軽い検証（キーフレーズ・`soundfile` で FLAC ヘッダ） |
| `test_ignore_pipeline_integration.py` | 上記 `heavy` 結合。環境変数とアセット両方が揃わない場合は skip |
| `test_stage2_asr_hints.py` | Whisper に渡す **`initial_prompt` / hotwords`** 用文字列や言語ヒント生成の単体検証 |
| `test_stage3_align_monotone.py` | **`_monotone_greedy_ranges`** と **`_pick_start_word`** の行列・スタブ前提の単体検証 |

加えて **`python/tests/test_pipeline_dummy.py`** は `test_*` 関数を持たないため **`pytest` では収集されない**。`python3 python/tests/test_pipeline_dummy.py` のように実行すると、`UX_MUSIC_LYRICS_SYNC_DUMMY=1` で CLI の subprocess を通すスタンドアロンのスモークになる。

---

## 5. Whisper 歌詞ヒント（本番・アプリ設定）

自動同期本体の ASR では、入力歌詞から **`initial_prompt` / hotwords`** を組み立てる（詳細は `python/lyrics_sync/stage2_asr.py`）。結合テストでは直接は網羅しないが、挙動切り替え用に次がある。

| 変数 | 意味 |
|:---|:---|
| `UX_MUSIC_WHISPER_LYRIC_PROMPT` | `0` / `false` / `no` で歌詞ベースの誘導をオフ |

---

## 6. CI での運用の目安

- **標準**: `make test-lyrics-sync`（`heavy` なし）のみ。`IGNORE/` が無ければ、アセット依存テストは **skip** で緑になりやすい。
- **結合 E2E** は、アセット鍵や長時間ランが使えない限り **`UX_MUSIC_IGNORE_INTEGRATION` をセットしない**（またはワークフローから除外する）。
- **`python/.venv`** や **`*.egg-info`** は一般的に無視される。ソースは **`python/lyrics_sync`** および **`python/tests`** が追跡対象となる（詳細はリポジトリの `.gitignore`）。

---

## 7. Go 側との関係

`internal/lyricssync/` には **サイドカーとの stdin/stdout 契約用**の Go テストがある。**歌詞処理の論理単体試験は主に Python 側**に置く。**`go test ./...`** と **`make test-lyrics-sync`** は両方とも通せる状態を維持するのがよい。

---

## 8. 既知の限界（テストでも暗黙になりがち）

- **`align()` を sentence-transformers まで通した本物の埋め込み**での回帰は、デフォルトの軽量 pytest セットにはほぼ含めていない。
- **英語行の音素経路（`g2p_en` と NLTK データ）は**環境により失敗しうる。そのため **`_pick_start_word`** の一部は **`phoneme_tokens` をスタブ**しており、クリーン環境でも安定して動くようにしている。
- 整列アルゴリズムの **単調グリード** と **間奏行がポインタを進めない仕様**は `test_stage3_align_monotone.py` で一部固定している。音声と歌詞が長尺・多言語になるほど **実データでの結合確認**が有効。

以上を、開発者向けに「どこまでが自動検証されていて、結合試験には何が必要か」の境界として参照してほしい。
