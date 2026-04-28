# Lyrics sync sidecar (`lyrics_sync`)

## いちばん簡単なローカルセットアップ（推奨）

リポジトリルートで一度だけ:

```bash
make lyrics-sync-python
# または: ./scripts/setup-lyrics-sync-python.sh
```

`uv` があれば自動で使い、なければ `python3 -m venv` にフォールバックします。  
完了後に `wails dev` をやり直せば、Go 側が **`python/.venv` を自動検出**して使います（環境変数の手当ては基本不要です）。

- 上書きしたいときだけ `UX_MUSIC_PYTHON` をセット
- Python バージョンは **3.10〜3.12**（`pyproject.toml` の `requires-python` に合わせる）

## Smoke check（GPU なし・ダミー）

```bash
UX_MUSIC_LYRICS_SYNC_DUMMY=1 PYTHONPATH=python python3 -m lyrics_sync --request <<<'{"songPath":"/dev/null","lines":["hello"]}'
```

## Windows

バンドル済み `python` と同じ階層に `.venv\Scripts\python.exe` を置けば、macOS/Linux と同様に自動検出されます。`HF_HOME` / `UX_MUSIC_MODEL_CACHE` は Go ホストが設定します。
