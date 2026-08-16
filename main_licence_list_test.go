package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestLicenceListContainsAllLinkedModules は、実際にバイナリへリンクされている
// Go モジュールがすべて設定画面のライセンス一覧（src/renderer/index.html）に
// 記載されていることを保証する。一覧のドリフト（モジュール追加時の記載漏れ）を
// 早期に検知するための回帰テスト。
//
// 逆方向（一覧にあるものが全てリンクされている）は意図的に検証しない。
// 一覧には同梱ネイティブバイナリや、現在の OS ではリンクされないプラットフォーム
// 固有モジュールの記載が正当に含まれるため。
func TestLicenceListContainsAllLinkedModules(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go バイナリが PATH に存在しないためスキップ")
	}

	cmd := exec.Command("go", "list", "-deps", "-f", "{{with .Module}}{{.Path}}{{end}}", ".")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("go list -deps の実行に失敗しました: %v", err)
	}

	htmlPath := filepath.Join("src", "renderer", "index.html")
	htmlBytes, err := os.ReadFile(htmlPath)
	if err != nil {
		t.Fatalf("%s の読み込みに失敗しました: %v", htmlPath, err)
	}
	html := string(htmlBytes)

	var missing []string
	for _, line := range strings.Split(string(out), "\n") {
		modulePath := strings.TrimSpace(line)
		if modulePath == "" || modulePath == "ux-music-sidecar" {
			continue
		}
		if !strings.Contains(html, modulePath) {
			missing = append(missing, modulePath)
		}
	}

	if len(missing) > 0 {
		t.Fatalf("リンクされているが %s に記載されていない Go モジュールがあります:\n  %s",
			htmlPath, strings.Join(missing, "\n  "))
	}
}
