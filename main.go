//go:build wails

package main

import (
	"embed"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

//go:embed all:src/renderer
var assets embed.FS

func main() {
	// Create an instance of the app structure
	app := NewApp()

	// Create application with options
	err := wails.Run(&options.App{
		Title:  "UX-Music",
		Width:  1024,
		Height: 768,
		AssetServer: &assetserver.Options{
			Assets: assets,
			Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				path := r.URL.Path
				if strings.HasPrefix(path, "/safe-artwork/") {
					// safe-artwork:// を /safe-artwork/path として受け取る
					filename := strings.TrimPrefix(path, "/safe-artwork/")
					userDataPath := config.GetUserDataPath()
					artworksDir := filepath.Join(userDataPath, "Artworks")
					fullPath := filepath.Join(artworksDir, filename)

					// セキュリティチェック: artworksDir 外のファイルへのアクセスを禁止
					if !strings.HasPrefix(fullPath, artworksDir) {
						http.Error(w, "Forbidden", http.StatusForbidden)
						return
					}

					data, err := os.ReadFile(fullPath)
					if err != nil {
						fmt.Printf("[Wails] Artwork read error: %v (path: %s)\n", err, fullPath)
						http.NotFound(w, r)
						return
					}
					// 簡易的な MIME タイプの判定
					contentType := "image/jpeg"
					if strings.HasSuffix(filename, ".png") {
						contentType = "image/png"
					} else if strings.HasSuffix(filename, ".webp") {
						contentType = "image/webp"
					}
					w.Header().Set("Content-Type", contentType)
					w.Write(data)
					return
				}
				http.NotFound(w, r)
			}),
		},
		BackgroundColour: &options.RGBA{R: 27, G: 38, B: 54, A: 1},
		OnStartup:        app.startup,
		Bind: []interface{}{
			app,
		},
		Debug: options.Debug{
			OpenInspectorOnStartup: true,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
