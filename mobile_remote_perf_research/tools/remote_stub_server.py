#!/usr/bin/env python3
"""Extended LAN API stub for reproducing/measuring Remote tab performance without a paired
desktop. Based on scripts/sidecar_stub_server.py (same UXM_DEBUG_SIDECAR_HOST/PORT hook is
reused to point serverConfig at this stub), but additionally serves the endpoints
RemoteLibraryScreen/RemoteControlScreen actually call:

  GET /v1/identity                    -> capabilities
  GET /v1/remote/songs                -> N fake songs (Services/RemoteAPIClient.swift fetchSongs)
  GET /v1/remote/loudness             -> {} (fetchLoudness)
  GET /v1/remote/situation-playlists  -> [] (fetchSituationPlaylists)
  GET /v1/remote/playlists            -> [] (fetchDesktopPlaylists)
  GET /v1/remote/artwork/?id=...      -> 1x1 PNG (ArtworkImageView)
  GET /v1/remote/state                -> same shape as sidecar_stub_server.py

Field names match Models/Song.swift's CodingKeys exactly (note: "albumartist", "type").

Usage:
    python3 mobile_remote_perf_research/tools/remote_stub_server.py --port 8799 --songs 500
"""
import argparse
import http.server
import json
import time

START = time.monotonic()

# 1x1 transparent PNG
PNG_1PX = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6360000002000155"
    "0002380f68170000000049454e44ae426082"
)

ALBUMS = ["Stub Album A", "Stub Album B", "Stub Album C", "Stub Album D", "Stub Album E"]
ARTISTS = ["Stub Artist 1", "Stub Artist 2", "Stub Artist 3"]


def make_songs(n: int):
    songs = []
    for i in range(n):
        album = ALBUMS[i % len(ALBUMS)]
        artist = ARTISTS[i % len(ARTISTS)]
        songs.append({
            "id": f"song-{i}",
            "path": f"/fake/{i}.m4a",
            "title": f"Stub Song {i}",
            "artist": artist,
            "album": album,
            "albumartist": artist,
            "year": 2020 + (i % 5),
            "genre": "Stub Genre",
            "duration": 180.0 + (i % 60),
            "trackNumber": (i % 12) + 1,
            "discNumber": 1,
            "fileSize": 4_000_000,
            "fileType": "m4a",
            "artworkId": f"art-{i % len(ALBUMS)}",
            "type": "local",
            "hasLocalAudio": True,
        })
    return songs


class Handler(http.server.BaseHTTPRequestHandler):
    songs_json = b"[]"
    duration = 210.0
    playing = True
    song_id = "stub-song-1"

    def log_message(self, fmt, *args):
        pass

    def _send_json(self, obj, status=200):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?")[0]

        if path == "/v1/identity":
            self._send_json({"capabilities": ["remote.relay.v1"], "name": "stub-desktop"})
            return

        if path == "/v1/remote/songs":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(Handler.songs_json)))
            self.end_headers()
            self.wfile.write(Handler.songs_json)
            return

        if path == "/v1/remote/loudness":
            self._send_json({})
            return

        if path == "/v1/remote/situation-playlists":
            self._send_json([])
            return

        if path == "/v1/remote/playlists":
            self._send_json([])
            return

        if path.startswith("/v1/remote/artwork/"):
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(PNG_1PX)))
            self.end_headers()
            self.wfile.write(PNG_1PX)
            return

        if path.startswith("/v1/remote/state"):
            elapsed = time.monotonic() - START
            position = elapsed % Handler.duration if Handler.playing else 0.0
            body = {
                "position": position,
                "duration": Handler.duration,
                "playing": Handler.playing,
                "title": "Stub Track Title",
                "artist": "Stub Artist",
                "album": "Stub Album",
                "songId": Handler.song_id,
                "artworkId": "art-0",
                "relay": {"active": False, "title": "", "thumbnail": ""},
                "localMuted": False,
                "sidecar": {"active": False},
            }
            self._send_json(body)
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)
        self._send_json({"ok": True})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8799)
    parser.add_argument("--songs", type=int, default=500)
    parser.add_argument("--song-id", type=str, default="stub-song-1")
    parser.add_argument("--no-playing", action="store_true")
    args = parser.parse_args()

    Handler.songs_json = json.dumps(make_songs(args.songs)).encode("utf-8")
    Handler.song_id = args.song_id
    Handler.playing = not args.no_playing

    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"[remote_stub_server] listening on 0.0.0.0:{args.port} songs={args.songs}")
    server.serve_forever()


if __name__ == "__main__":
    main()
