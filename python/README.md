# Lyrics sync sidecar (`lyrics_sync`)

Install (development):

Wails が起動する `python3` は **依存関係を入れた仮想環境** に向けるか、`PYTHONPATH` と同じ環境へ `pip install` 済みにしてください。**システムの `python3` のまま**だと `No module named 'faster_whisper'` になります。

```bash
cd python
# Python 3.10〜3.12 を推奨（pyproject.toml の requires-python と合わせる）
uv venv --python 3.12 && source .venv/bin/activate   # Windows: .venv\Scripts\activate
uv pip install -e '.[dev]'
# アプリ側で UX_MUSIC_PYTHON=/path/to/python のようにこの venv の python を指定
```

**Windows**: set `PYTHONPATH` to this `python` directory when invoking `python -m lyrics_sync --request`; set `HF_HOME`/`UX_MUSIC_MODEL_CACHE` user-data paths as emitted by the Go host. FFmpeg and Demucs prerequisites match PyTorch CUDA/CPU installs documented upstream.

Smoke check without ML downloads:

```bash
UX_MUSIC_LYRICS_SYNC_DUMMY=1 PYTHONPATH=python python3 -m lyrics_sync --request <<<'{"songPath":"/dev/null","lines":["hello"]}'
```
