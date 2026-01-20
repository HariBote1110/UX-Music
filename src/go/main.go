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
	// ログは stderr に出す (stdout は通信用)
	fmt.Fprintln(os.Stderr, "[Go] Sidecar started")

	for scanner.Scan() {
		line := scanner.Text()
		fmt.Fprintf(os.Stderr, "[Go] Received: %s\n", line)

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
	case "scan-library":
		var paths []string
		// Payload を []string に変換
		if err := json.Unmarshal(req.Payload, &paths); err != nil {
			sendError("invalid_payload", "Payload must be an array of strings")
			return
		}
		result := ScanLibrary(paths)
		sendResponse("scan-library-success", result)
	default:
		sendError("unknown_command", fmt.Sprintf("Command '%s' not found", req.Type))
	}
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
