package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

// Request はElectronから送られてくるJSONメッセージの形式
type Request struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// Response はElectronへ返すJSONメッセージの形式
type Response struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
	Error   string      `json:"error,omitempty"`
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	fmt.Fprintln(os.Stderr, "[Go] Sidecar started")

	for scanner.Scan() {
		line := scanner.Text()
		// ログが多すぎると邪魔なのでデバッグ時のみ有効化を検討
		// fmt.Fprintf(os.Stderr, "[Go] Received: %s\n", line)

		var req Request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			sendError("invalid_json", err.Error())
			continue
		}

		handleRequest(req)
	}
}

func handleRequest(req Request) {
	switch req.Type {
	case "ping":
		sendResponse("pong", map[string]string{"message": "Hello from Go Sidecar!"})

	case "init":
		var payload struct {
			UserDataPath string `json:"userDataPath"`
			FFmpegPath   string `json:"ffmpegPath"`
			FFprobePath  string `json:"ffprobePath"`
		}
		if parsePayload(req.Payload, &payload) {
			config.SetUserDataPath(payload.UserDataPath)
			// Analyzer 用のパス設定
			SetAnalyzerPaths(payload.FFmpegPath, payload.FFprobePath)
			sendResponse("init-success", nil)
		}

	case "scan-library":
		var paths []string
		if parsePayload(req.Payload, &paths) {
			result := ScanLibrary(paths)
			sendResponse("scan-library-success", result)
		}

	// --- Analyzer ---
	case "analyze-song":
		var payload struct {
			Path string `json:"path"`
		}
		if parsePayload(req.Payload, &payload) {
			result, err := AnalyzeSong(payload.Path)
			if err != nil {
				sendError("analysis-error", err.Error())
			} else {
				sendResponse("analysis-success", result)
			}
		}

	// --- Store ---
	case "store-load":
		var payload struct {
			Name string `json:"name"`
		}
		if parsePayload(req.Payload, &payload) {
			data, err := stores.Load(payload.Name)
			if err != nil {
				sendError("store-error", err.Error())
			} else {
				sendResponse("store-loaded", data)
			}
		}

	case "store-save":
		var payload struct {
			Name string      `json:"name"`
			Data interface{} `json:"data"`
		}
		if parsePayload(req.Payload, &payload) {
			err := stores.Save(payload.Name, payload.Data)
			if err != nil {
				sendError("store-error", err.Error())
			} else {
				sendResponse("store-saved", nil)
			}
		}

	// --- Lyrics ---
	case "get-lyrics":
		var payload struct {
			Title string `json:"title"`
			Path  string `json:"path"` // optional fallback
		}
		if parsePayload(req.Payload, &payload) {
			result, err := FindLyrics(payload.Title)
			if err != nil {
				sendError("lyrics-error", err.Error())
			} else {
				sendResponse("lyrics-found", result)
			}
		}

	case "save-lrc":
		var payload struct {
			FileName string `json:"fileName"`
			Content  string `json:"content"`
		}
		if parsePayload(req.Payload, &payload) {
			err := SaveLrcFile(payload.FileName, payload.Content)
			if err != nil {
				sendError("lyrics-error", err.Error())
			} else {
				sendResponse("lrc-saved", nil)
			}
		}

	// --- Playlist ---
	case "get-all-playlists":
		names, err := GetAllPlaylists()
		if err != nil {
			sendError("playlist-error", err.Error())
		} else {
			sendResponse("all-playlists", names)
		}

	case "get-playlist-songs":
		var payload struct {
			Name string `json:"name"`
		}
		if parsePayload(req.Payload, &payload) {
			songs, err := GetPlaylistSongs(payload.Name)
			if err != nil {
				sendError("playlist-error", err.Error())
			} else {
				sendResponse("playlist-songs", songs)
			}
		}

	case "create-playlist":
		var payload struct {
			Name string `json:"name"`
		}
		if parsePayload(req.Payload, &payload) {
			err := CreatePlaylist(payload.Name)
			if err != nil {
				sendError("playlist-error", err.Error())
			} else {
				sendResponse("playlist-created", nil)
			}
		}

	default:
		sendError("unknown_command", fmt.Sprintf("Command '%s' not found", req.Type))
	}
}

func parsePayload(raw json.RawMessage, target interface{}) bool {
	if err := json.Unmarshal(raw, target); err != nil {
		sendError("invalid_payload", err.Error())
		return false
	}
	return true
}

func sendResponse(resType string, payload interface{}) {
	res := Response{
		Type:    resType,
		Payload: payload,
	}
	bytes, _ := json.Marshal(res)
	fmt.Println(string(bytes)) // stdout に書き込むことで Electron に送信
}

func sendError(errType string, message string) {
	res := Response{
		Type:  errType,
		Error: message,
	}
	bytes, _ := json.Marshal(res)
	fmt.Println(string(bytes))
}
