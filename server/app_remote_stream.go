package server

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strconv"
)

// streamProcessStartedHook, when non-nil, is invoked with the PID of the
// ffmpeg process started for a GET /v1/remote/file/{id}?stream=aac request.
// Test-only seam (app_remote_stream_test.go) used to verify that a client
// disconnect actually kills and reaps the ffmpeg process rather than
// leaking it. nil in production.
var streamProcessStartedHook func(pid int)

// streamFfmpegPath is an injection seam mirroring relayEngine.ffmpegPath;
// production always resolves to locateFfmpeg. Kept as a var (rather than a
// direct call) so tests can force the "ffmpeg not found" path without
// touching the real PATH.
var streamFfmpegPath = locateFfmpeg

// serveFileStreamAAC streams inputPath through ffmpeg as ADTS AAC-LC,
// 256kbps 44.1kHz stereo — byte-compatible with GET /v1/remote/relay's
// format (see relayAACBitrateKbps) so TV clients can reuse the exact same
// ADTS decode pipeline for both endpoints.
//
// Unlike getOrTranscode's cached m4a (used for the plain, non-streaming
// GET /v1/remote/file/{id}), this never waits for a full transcode: ffmpeg's
// stdout is piped straight to the HTTP response as bytes are produced, so a
// TV with no cached copy can start audible playback well under a second in,
// while the original file downloads separately (in parallel) via a plain
// request without ?stream=.
//
// The response has no Content-Length (chunked transfer — the encoded size
// isn't known upfront) so Range requests are not honoured in this mode; see
// the caller in remoteFileHandler. If the client disconnects mid-stream,
// r.Context() is cancelled by net/http, which — via exec.CommandContext —
// kills ffmpeg instead of leaving it encoding into nobody.
func serveFileStreamAAC(w http.ResponseWriter, r *http.Request, inputPath string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeAPIError(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	ffmpegPath, err := streamFfmpegPath()
	if err != nil {
		writeAPIError(w, "ffmpeg not found", http.StatusInternalServerError)
		return
	}

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	cmd := exec.CommandContext(ctx, ffmpegPath,
		"-i", inputPath,
		"-vn",
		"-c:a", "aac",
		"-b:a", strconv.Itoa(relayAACBitrateKbps)+"k",
		"-ar", "44100",
		"-ac", "2",
		// Same lesson as relayEngine.Start (progress/remote-relay.md): without
		// this, ffmpeg batches ADTS frames in its internal avio buffer and
		// only flushes them when the buffer fills or the process exits —
		// fatal for a live stream, where "on exit" means "after the whole
		// file", defeating the point of streaming.
		"-flush_packets", "1",
		"-f", "adts",
		"pipe:1",
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeAPIError(w, "ffmpeg stdout pipe failed", http.StatusInternalServerError)
		return
	}
	if err := cmd.Start(); err != nil {
		writeAPIError(w, "ffmpeg start failed", http.StatusInternalServerError)
		return
	}
	if streamProcessStartedHook != nil {
		streamProcessStartedHook(cmd.Process.Pid)
	}
	defer func() {
		// Idempotent even if the loop below already exited because ffmpeg
		// finished on its own: cancel is a no-op once the process is gone,
		// and Wait reaps whichever of the two happened.
		cancel()
		_ = cmd.Wait()
	}()

	w.Header().Set("Content-Type", "audio/aac")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	buf := make([]byte, 4096)
	for {
		n, readErr := stdout.Read(buf)
		if n > 0 {
			if _, writeErr := w.Write(buf[:n]); writeErr != nil {
				// Client gone; let the deferred cancel/Wait above reap ffmpeg.
				return
			}
			flusher.Flush()
		}
		if readErr != nil {
			if readErr != io.EOF {
				fmt.Printf("[Remote] stream transcode read error: %v (stderr: %s)\n", readErr, stderr.String())
			}
			return
		}
	}
}
