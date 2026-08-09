#!/usr/bin/env python3
"""Measure the expected size reduction of transcoding the UX Music library to AAC 128 kbps.

Reads library.json from the desktop app's user-data directory, samples N songs,
reads each file's size and duration (afinfo), and reports the original vs
predicted-AAC128 sizes. AAC size is estimated as duration * 128 kbps * 1.04
(container overhead) — cross-checked against the desktop server's ffmpeg output.

Usage: python3 measure_library_reduction.py [sample_size]
"""
import json
import os
import random
import statistics
import subprocess
import sys

USER_DATA = os.path.expanduser("~/Library/Application Support/UX-Music")
SAMPLE = int(sys.argv[1]) if len(sys.argv) > 1 else 40
AUDIO_EXTS = (".flac", ".mp3", ".m4a", ".wav", ".ogg", ".aac", ".aiff")


def extract_paths(obj, out):
    if isinstance(obj, dict):
        for v in obj.values():
            extract_paths(v, out)
    elif isinstance(obj, list):
        for v in obj:
            extract_paths(v, out)
    elif isinstance(obj, str):
        if obj.startswith("/") and os.path.splitext(obj)[1].lower() in AUDIO_EXTS:
            out.append(obj)


def duration_seconds(path):
    try:
        out = subprocess.run(["afinfo", path], capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            if "estimated duration" in line:
                return float(line.split(":")[1].strip().split()[0])
    except Exception:
        pass
    return None


def main():
    with open(os.path.join(USER_DATA, "library.json")) as f:
        lib = json.load(f)
    paths = []
    extract_paths(lib, paths)
    paths = list(dict.fromkeys(paths))
    existing = [p for p in paths if os.path.exists(p)]
    print(f"paths: {len(paths)}, existing: {len(existing)}")

    exts = {}
    for s in existing:
        e = os.path.splitext(s)[1].lower()
        exts[e] = exts.get(e, 0) + 1
    print("extensions:", exts)

    random.seed(42)
    data = []
    for s in random.sample(existing, min(SAMPLE, len(existing))):
        dur = duration_seconds(s)
        if dur:
            data.append((s, os.path.getsize(s), dur))

    origs = [d[1] for d in data]
    aacs = [d[2] * 128_000 / 8 * 1.04 for d in data]
    print(f"\nsampled with duration: {len(data)}")
    print(f"mean original: {statistics.mean(origs) / 1e6:.1f} MB, median: {statistics.median(origs) / 1e6:.1f} MB")
    print(f"mean AAC128:   {statistics.mean(aacs) / 1e6:.1f} MB")
    print(f"mean per-file reduction: {statistics.mean(o / a for o, a in zip(origs, aacs)):.1f}x")
    print(f"aggregate reduction:     {sum(origs) / sum(aacs):.1f}x")

    by = {}
    for (s, size, dur), aac in zip(data, aacs):
        by.setdefault(os.path.splitext(s)[1].lower(), []).append((size, aac))
    for e, rows in sorted(by.items()):
        print(
            f"  {e}: n={len(rows)}, mean orig {statistics.mean(r[0] for r in rows) / 1e6:.1f} MB, "
            f"reduction {sum(r[0] for r in rows) / sum(r[1] for r in rows):.1f}x"
        )


if __name__ == "__main__":
    main()
