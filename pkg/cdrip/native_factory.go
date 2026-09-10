package cdrip

import "os"

var nativeDiscFactory = openNativeDisc

type NativeDiscDevice struct {
	BSDName string
	Path    string
}

func nativeReaderEnabled() bool { return os.Getenv("UX_MUSIC_CDRIP_NATIVE") == "1" }
