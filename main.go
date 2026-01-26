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
	"github.com/wailsapp/wails/v2/pkg/options/mac"
)

//go:embed all:src/renderer
var assets embed.FS

func main() {
	// UserDataPath の初期化 (AssetHandler でも使用するため wails.Run の前に実行)
	configDir, _ := os.UserConfigDir()
	userDataPath := filepath.Join(configDir, "ux-music")
	config.SetUserDataPath(userDataPath)

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

					// http.ServeFile を使用してメモリ効率を高める（ストリーミング配信）
					http.ServeFile(w, r, fullPath)
					return
				} else if strings.HasPrefix(path, "/safe-media/") {
					// Wails 環境での音楽再生用
					relPath := strings.TrimPrefix(path, "/safe-media/")
					// filepath.Clean で // などを正規化し、OSに依存しないスラッシュにする
					// ただし Mac の絶対パスを維持するため、先頭に / を付ける
					fullPath := "/" + filepath.Clean(relPath)

					if _, err := os.Stat(fullPath); err != nil {
						fmt.Printf("[Wails] Media file not found: %s (error: %v)\n", fullPath, err)
						http.NotFound(w, r)
						return
					}

					// fmt.Printf("[Wails] Serving media: %s\n", fullPath) // 頻度が高いので必要時のみ有効化
					http.ServeFile(w, r, fullPath)
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
		Mac: &mac.Options{
			TitleBar: &mac.TitleBar{
				TitlebarAppearsTransparent: true,
				HideTitle:                  true,
				HideTitleBar:               false,
				FullSizeContent:            true,
				UseToolbar:                 false,
			},
			WindowIsTranslucent: false,
		},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
