# 歌詞で Whisper を誘導する案（保留中・未取り込み）

## 決定

**Whisper の ASR に入力歌詞をヒントとして与える案（`initial_prompt` / hotwords）を、現時点では取り込まない。** アイデア自体は有効だが、試作されたコードは現行の `stage3_align` より前の系統に載っており、そのまま cherry-pick すると古い整列ロジックを引き戻すため。

試作は `origin/archive/lyrics-sync-old-main` の以下に保全してある。

| コミット | 内容 | 扱い |
|---|---|---|
| `ff33693` | feat(lyrics-sync): Whisper を歌詞で誘導し行頭とASR語の対応を改善 | **保留（アイデアは有効・移植は未実施）** |
| `71c3e54` | fix(lyrics-sync): 間奏付近の疎いASRセグメントを抑え埋め込み弱一致時は後方の音声へ再探索 | **破棄**（下記のとおり現行版が上位互換） |
| `0094cb3` | test: stage3_align の実装に合わせて単体テストを更新 | **破棄**（旧実装に紐づくため） |

## なぜ 71c3e54 を破棄したか

`origin/main` 側の `stage3_align.py` は 783 行、旧系統は 202 行で、同じ問題領域に対して現行版が遥かに作り込まれている。現行版が持つ修復処理：

- `_repair_large_jump_snap`
- `_repair_isolated_gap_tail`
- `_repair_repeated_block_tail_extension`
- `_repair_forward_drift_to_skipped_segments`
- `_enforce_monotone_progress`
- `phoneme.is_interlude` による間奏行の一貫した除外

旧系統の「間奏付近の疎いセグメント抑制・後方への再探索」はこれらに包含される。取り込む価値がない。

## なぜ ff33693 は保留（破棄ではない）か

現行の `stage2_asr.py` には**歌詞ベースの誘導が一切存在しない**（`initial_prompt` / hotwords / lyric いずれの参照もなし）。つまりこれは現行版に無い独自のアイデアで、失うと惜しい。

ただし取り込みは cherry-pick ではなく**現行実装への移植**になる。試作コミットは `stage2_asr.py`（54 行）だけでなく `stage3_align.py`（161 行）と `pipeline.py` も同時に書き換えており、後者 2 つは現行版と全く別物だから。

## 移植する場合にやること

1. `ff33693` の `stage2_asr.py` 差分のみを参照し、歌詞から `initial_prompt` / hotwords を組み立てる処理を現行版へ書き直す。
2. 挙動切り替えの環境変数 `UX_MUSIC_WHISPER_LYRIC_PROMPT`（`0`/`false`/`no` で無効）も併せて実装する。
3. 単体テストを新規に書く（試作の `test_stage2_asr_hints.py` は旧実装の関数シグネチャ前提なので流用不可）。
4. 効果測定は `python/tests/sync_accuracy.py` の指標で、移植前後を実アセットで比較する。ヒントが誤った語へ引っ張る副作用があり得るため、体感ではなく指標で確認すること。

## 注意点

- `markdown/testing-lyrics-sync.md` は当初この機能が存在する前提で書かれていた。実態に合わせて「未実装」と明記済み。移植したらこの記述も戻すこと。
- 退避ブランチ `origin/archive/lyrics-sync-old-main` は、この移植が済むか、不要と判断されるまで削除しないこと。
