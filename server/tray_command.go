package server

// トレイメニューが発行するコマンドの列挙値。macOS 固有の内容は一切無い
// ただの整数定数なので、tray_darwin.go / tray_stub.go のどちらでも
// （つまり全プラットフォームで）参照できるよう、ビルド制約を持たない
// このファイルに置く。かつては tray_darwin.go にあり //go:build darwin
// の影響で非 darwin ビルドが app_tray.go の参照を解決できず落ちていた。
const (
	trayCommandShowWindow = 1
	trayCommandPlayPause  = 2
	trayCommandNext       = 3
	trayCommandPrevious   = 4
	trayCommandQuit       = 5
)
