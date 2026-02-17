//go:build !darwin

package main

func registerOSMediaCommands(callback func(string)) error {
	_ = callback
	return nil
}

func setOSNowPlaying(title string, artist string, album string, playing bool) {
	_, _, _, _ = title, artist, album, playing
}

func clearOSNowPlaying() {}
