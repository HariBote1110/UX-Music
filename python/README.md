# Lyrics sync sidecar (`lyrics_sync`)

Install (development):

```bash
cd python
uv venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
uv pip install -e '.[dev]'
```

**Windows**: set `PYTHONPATH` to this `python` directory when invoking `python -m lyrics_sync --request`; set `HF_HOME`/`UX_MUSIC_MODEL_CACHE` user-data paths as emitted by the Go host. FFmpeg and Demucs prerequisites match PyTorch CUDA/CPU installs documented upstream.

Smoke check without ML downloads:

```bash
UX_MUSIC_LYRICS_SYNC_DUMMY=1 PYTHONPATH=python python3 -m lyrics_sync --request <<<'{"songPath":"/dev/null","lines":["hello"]}'
```
