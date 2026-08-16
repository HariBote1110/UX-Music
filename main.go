package main

import (
	"embed"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/menu"
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

	if handled, err := server.RunSyncCLI(os.Args[1:]); handled {
		if err != nil {
			println("Error:", err.Error())
			os.Exit(1)
		}
		return
	}

	server.SetServerMode(server.ModeGUI)

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
		// HideWindowOnClose keeps the process (audio playback, the LAN API
		// on port 8765, the YouTube embed relay) running in the background
		// when the window's close button is clicked: macOS hides the window
		// natively instead of closing it, and clicking the Dock icon
		// re-shows it via AppKit's default unhide behaviour. See
		// progress/background-window-close.md for the investigation.
		HideWindowOnClose: true,
		OnStartup:         app.Startup,
		OnShutdown:        app.Shutdown,
		OnBeforeClose:     app.BeforeClose,
		// AppMenu supplies the standard "Quit <App>" item bound to Cmd+Q,
		// which is what lets the app really quit (as opposed to hiding via
		// HideWindowOnClose above).
		Menu: menu.NewMenuFromItems(menu.AppMenu(), menu.EditMenu()),
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
