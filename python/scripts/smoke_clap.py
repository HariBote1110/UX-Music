"""CLAP smoke test: load checkpoint, embed one audio file, sanity-check shape.

Run: python/.venv/bin/python3 python/scripts/smoke_clap.py
Optional: pass an audio file path as the first argument; otherwise a short
librosa-bundled sample is used.
"""

from __future__ import annotations

import os
import sys
import time
import warnings

warnings.filterwarnings("ignore")

import numpy as np  # noqa: E402
import torch  # noqa: E402

CHECKPOINT = "music_audioset_epoch_15_esc_90.14.pt"


def _resolve_audio_path() -> str:
    if len(sys.argv) > 1:
        return os.path.abspath(sys.argv[1])
    import librosa

    return librosa.example("trumpet")


def main() -> None:
    audio_path = _resolve_audio_path()
    if not os.path.exists(audio_path):
        print(f"audio not found: {audio_path}", file=sys.stderr)
        sys.exit(1)
    print(f"audio: {audio_path}")

    import laion_clap

    print(f"loading CLAP checkpoint: {CHECKPOINT} (downloads ~2.2GB on first run)")
    t0 = time.time()
    model = laion_clap.CLAP_Module(enable_fusion=True, amodel="HTSAT-tiny")
    model.load_ckpt(model_id=3)  # music_audioset_epoch_15_esc_90.14.pt (HTSAT-tiny + fusion)
    print(f"loaded in {time.time() - t0:.1f}s")

    print("encoding audio…")
    t0 = time.time()
    audio_embed = model.get_audio_embedding_from_filelist(x=[audio_path], use_tensor=False)
    print(f"audio encoded in {time.time() - t0:.2f}s")

    print("encoding text queries…")
    t0 = time.time()
    text_embed = model.get_text_embedding(
        ["a cheerful trumpet solo", "heavy metal guitar", "quiet piano ballad"],
        use_tensor=False,
    )
    print(f"text encoded in {time.time() - t0:.2f}s")

    av = np.asarray(audio_embed)
    tv = np.asarray(text_embed)
    print(f"audio shape: {av.shape}, dtype: {av.dtype}")
    print(f"text  shape: {tv.shape}, dtype: {tv.dtype}")
    assert av.shape[1] == 512, f"expected 512-dim audio embedding, got {av.shape}"
    assert tv.shape[1] == 512, f"expected 512-dim text embedding, got {tv.shape}"

    def cos(a, b):
        return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))

    a = av[0]
    print("cosine similarity (audio vs text):")
    for i, q in enumerate(
        ["a cheerful trumpet solo", "heavy metal guitar", "quiet piano ballad"]
    ):
        print(f"  {q!r}: {cos(a, tv[i]):+.4f}")

    print("smoke ok")


if __name__ == "__main__":
    main()
