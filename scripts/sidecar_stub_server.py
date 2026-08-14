#!/usr/bin/env python3
"""Minimal /v1/remote/state stub for reproducing the sidecar CPU/RSS leak on-device
without a real desktop paired. Mirrors the JSON shape from server/app_remote.go's
remoteStateHandler. Any Authorization header is accepted (no token check) since the
mobile app always sends one.

Usage:
    python3 sidecar_stub_server.py [--port 8799] [--song-id ""] [--no-playing]

Pair with UX-Music-Mobile's UXM_DEBUG_SIDECAR_HOST/UXM_DEBUG_SIDECAR_PORT debug hook
(see UXMusicMobileApp.swift):

    python3 scripts/sidecar_stub_server.py --port 8799 &
    xcrun simctl install <udid> <path-to>.app
    SIMCTL_CHILD_UXM_DEBUG_SIDECAR_HOST=127.0.0.1 SIMCTL_CHILD_UXM_DEBUG_SIDECAR_PORT=8799 \
        xcrun simctl launch <udid> com.uxlabs.uxMusicMobile

Serves on 0.0.0.0 so the simulator (which shares the host's loopback) can reach it at
127.0.0.1:<port>.
"""
import argparse
import http.server
import json
import time

START = time.monotonic()


class Handler(http.server.BaseHTTPRequestHandler):
    song_id = "stub-song-1"
    duration = 210.0
    playing = True
    lrc_content = None

    def log_message(self, fmt, *args):
        pass  # keep stdout quiet; measurements read ps/log separately

    def do_GET(self):
        if self.path.startswith("/v1/remote/state"):
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
                "artworkId": "",
                "relay": {"active": False, "title": "", "thumbnail": ""},
                "localMuted": False,
                "sidecar": {"active": True},
            }
            payload = json.dumps(body).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/v1/remote/lyrics"):
            if Handler.lrc_content is not None:
                body = json.dumps({"found": True, "type": "lrc", "content": Handler.lrc_content}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            # Realistic 404 unless songId is empty (fuzzy-match path never fetches lyrics
            # by songId anyway) -- exercises SidecarScreen's optional-lyrics error path.
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            body = json.dumps({"error": "not found"}).encode("utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8799)
    parser.add_argument("--song-id", type=str, default="stub-song-1")
    parser.add_argument("--no-playing", action="store_true")
    parser.add_argument("--lrc-file", type=str, default=None, help="Serve this file's content as dense LRC lyrics for /v1/remote/lyrics.")
    args = parser.parse_args()

    Handler.song_id = args.song_id
    Handler.playing = not args.no_playing
    if args.lrc_file:
        with open(args.lrc_file, "r", encoding="utf-8") as f:
            Handler.lrc_content = f.read()

    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"[sidecar_stub_server] listening on 0.0.0.0:{args.port} songId={args.song_id!r} playing={Handler.playing}")
    server.serve_forever()


if __name__ == "__main__":
    main()
