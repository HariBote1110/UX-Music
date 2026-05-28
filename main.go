package main

import (
	"embed"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/mac"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/server"
)

//go:embed all:src/renderer/dist
var assets embed.FS

func main() {
	// UserDataPath の初期化 (AssetHandler でも使用するため wails.Run の前に実行)
	configDir, _ := os.UserConfigDir()
	userDataPath := filepath.Join(configDir, "ux-music")
	config.SetUserDataPath(userDataPath)

	// Create an instance of the app structure
	app := server.NewApp()

	// Create application with options
	err := wails.Run(&options.App{
		Title:  "UX-Music",
		Width:  1024,
		Height: 768,
		AssetServer: &assetserver.Options{
			Assets:  assets,
			Handler: newAssetHandler(),
		},
		BackgroundColour: &options.RGBA{R: 27, G: 38, B: 54, A: 1},
		OnStartup:        app.Startup,
		Bind: []interface{}{
			app,
		},
		Debug: options.Debug{
			OpenInspectorOnStartup: true,
		},
		DragAndDrop: &options.DragAndDrop{
			EnableFileDrop:     true,
			DisableWebViewDrop: true,
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
