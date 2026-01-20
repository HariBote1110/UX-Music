package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

// Request はElectronから送られてくるJSONメッセージの形式
type Request struct {
	ID      string          `json:"id,omitempty"` // リクエストID (レスポンス紐付け用)
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// Response はElectronへ返すJSONメッセージの形式
type Response struct {
	ID      string      `json:"id,omitempty"` // リクエストのIDをそのまま返す
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
	Error   string      `json:"error,omitempty"`
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	// ログは stderr に出す (stdout は通信用)
	fmt.Fprintln(os.Stderr, "[Go] Sidecar started")

	for scanner.Scan() {
		line := scanner.Text()
		// ログが多すぎると邪魔なのでデバッグ時のみ有効化を検討
		// fmt.Fprintf(os.Stderr, "[Go] Received: %s\n", line)

		var req Request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			sendError("", "invalid_json", err.Error())
			continue
		}

		handleRequest(req)
	}
}

func handleRequest(req Request) {
	// ヘルパー関数: IDを引き継いでレスポンス
	respond := func(resType string, payload interface{}) {
		sendResponse(req.ID, resType, payload)
	}
	fail := func(errType string, message string) {
		sendError(req.ID, errType, message)
	}

	switch req.Type {
	case "ping":
		respond("pong", map[string]string{"message": "Hello from Go Sidecar!"})

	case "init":
		var payload struct {
			UserDataPath string `json:"userDataPath"`
			FFmpegPath   string `json:"ffmpegPath"`
			FFprobePath  string `json:"ffprobePath"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			config.SetUserDataPath(payload.UserDataPath)
			// Analyzer 用のパス設定
			SetAnalyzerPaths(payload.FFmpegPath, payload.FFprobePath)
			respond("init-success", nil)
		}

	case "scan-library":
		var paths []string
		if parsePayload(req.ID, req.Payload, &paths) {
			result := ScanLibrary(paths)
			respond("scan-library-success", result)
		}

	// --- Analyzer ---
	case "analyze-song":
		var payload struct {
			Path string `json:"path"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			result, err := AnalyzeSong(payload.Path)
			if err != nil {
				fail("analysis-error", err.Error())
			} else {
				respond("analysis-success", result)
			}
		}

	// --- Store ---
	case "store-load":
		var payload struct {
			Name string `json:"name"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			data, err := stores.Load(payload.Name)
			if err != nil {
				fail("store-error", err.Error())
			} else {
				respond("store-loaded", data)
			}
		}

	case "store-save":
		var payload struct {
			Name string      `json:"name"`
			Data interface{} `json:"data"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			err := stores.Save(payload.Name, payload.Data)
			if err != nil {
				fail("store-error", err.Error())
			} else {
				respond("store-saved", nil)
			}
		}

	// --- Lyrics ---
	case "get-lyrics":
		var payload struct {
			Title string `json:"title"`
			Path  string `json:"path"` // optional fallback
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			result, err := FindLyrics(payload.Title)
			if err != nil {
				fail("lyrics-error", err.Error())
			} else {
				respond("lyrics-found", result)
			}
		}

	case "save-lrc":
		var payload struct {
			FileName string `json:"fileName"`
			Content  string `json:"content"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			err := SaveLrcFile(payload.FileName, payload.Content)
			if err != nil {
				fail("lyrics-error", err.Error())
			} else {
				respond("lrc-saved", nil)
			}
		}

	// --- Playlist ---
	case "get-all-playlists":
		names, err := GetAllPlaylists()
		if err != nil {
			fail("playlist-error", err.Error())
		} else {
			respond("all-playlists", names)
		}

	case "get-playlist-songs":
		var payload struct {
			Name string `json:"name"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			songs, err := GetPlaylistSongs(payload.Name)
			if err != nil {
				fail("playlist-error", err.Error())
			} else {
				respond("playlist-songs", songs)
			}
		}

	case "create-playlist":
		var payload struct {
			Name string `json:"name"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			err := CreatePlaylist(payload.Name)
			if err != nil {
				fail("playlist-error", err.Error())
			} else {
				respond("playlist-created", nil)
			}
		}

	case "delete-playlist":
		var payload struct {
			Name string `json:"name"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			err := DeletePlaylist(payload.Name)
			if err != nil {
				fail("playlist-error", err.Error())
			} else {
				respond("playlist-deleted", nil)
			}
		}

	case "rename-playlist":
		var payload struct {
			OldName string `json:"oldName"`
			NewName string `json:"newName"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			err := RenamePlaylist(payload.OldName, payload.NewName)
			if err != nil {
				fail("playlist-error", err.Error())
			} else {
				respond("playlist-renamed", nil)
			}
		}

	case "update-playlist-order":
		var payload struct {
			Name  string   `json:"name"`
			Paths []string `json:"paths"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			err := UpdatePlaylistOrder(payload.Name, payload.Paths)
			if err != nil {
				fail("playlist-error", err.Error())
			} else {
				respond("playlist-order-updated", nil)
			}
		}

	case "add-songs-to-playlist":
		var payload struct {
			Name  string      `json:"name"`
			Songs []SongToAdd `json:"songs"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			count, err := AddSongsToPlaylist(payload.Name, payload.Songs)
			if err != nil {
				fail("playlist-error", err.Error())
			} else {
				respond("songs-added-to-playlist", map[string]int{"count": count})
			}
		}

	case "remove-songs-from-playlist":
		var payload struct {
			Name  string   `json:"name"`
			Paths []string `json:"paths"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			err := RemoveSongsFromPlaylist(payload.Name, payload.Paths)
			if err != nil {
				fail("playlist-error", err.Error())
			} else {
				respond("songs-removed-from-playlist", nil)
			}
		}

	// --- MTP Sidecar ---
	case "mtp-test":
		var payload struct {
			ScriptPath string `json:"scriptPath"`
		}
		if parsePayload(req.ID, req.Payload, &payload) {
			sidecar := NewNodeSidecar(payload.ScriptPath)
			if err := sidecar.Start(); err != nil {
				fail("mtp-error", err.Error())
				return
			}
			defer sidecar.Stop()

			// Send init command to MTP sidecar
			initResp, err := sidecar.Invoke("init", nil)
			if err != nil {
				fail("mtp-error", err.Error())
				return
			}

			respond("mtp-test-result", map[string]interface{}{
				"sidecarResponse": initResp,
			})
		}

	default:
		fail("unknown_command", fmt.Sprintf("Command '%s' not found", req.Type))

	}
}

func parsePayload(id string, raw json.RawMessage, target interface{}) bool {
	if err := json.Unmarshal(raw, target); err != nil {
		sendError(id, "invalid_payload", err.Error())
		return false
	}
	return true
}

func sendResponse(id string, resType string, payload interface{}) {
	res := Response{
		ID:      id,
		Type:    resType,
		Payload: payload,
	}
	bytes, _ := json.Marshal(res)
	fmt.Println(string(bytes)) // stdout に書き込むことで Electron に送信
}

func sendError(id string, errType string, message string) {
	res := Response{
		ID:    id,
		Type:  errType,
		Error: message,
	}
	bytes, _ := json.Marshal(res)
	fmt.Println(string(bytes))
}
