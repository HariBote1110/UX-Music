//go:build darwin

package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"strconv"

	"ux-music-sidecar/pkg/cdrip"
)

func main() {
	if len(os.Args) < 2 || len(os.Args) > 3 {
		fmt.Fprintln(os.Stderr, "usage: cdrip-compare <track-number> [output.wav]")
		os.Exit(2)
	}
	trackNumber, err := strconv.Atoi(os.Args[1])
	if err != nil || trackNumber < 1 {
		fmt.Fprintf(os.Stderr, "invalid track number: %q\n", os.Args[1])
		os.Exit(2)
	}
	output := fmt.Sprintf("native-track-%d.wav", trackNumber)
	if len(os.Args) == 3 {
		output = os.Args[2]
	}
	reader, err := cdrip.OpenNativeDisc()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer reader.Close()
	toc, err := reader.ReadTOC()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var sectors int
	for _, track := range toc.Tracks {
		if track.Number == trackNumber && track.Audio {
			sectors = track.Length
			break
		}
	}
	if sectors == 0 {
		fmt.Fprintf(os.Stderr, "audio track %d not found\n", trackNumber)
		os.Exit(1)
	}
	hash := sha256.New()
	err = cdrip.WritePCM16LEStream(output, int64(sectors*cdrip.CDSectorBytes), func(writer io.Writer) error {
		_, err := cdrip.SecureReadTrackTo(io.MultiWriter(writer, hash), reader, trackNumber, cdrip.SecureReadOptions{})
		return err
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("%s  %x\n", output, hash.Sum(nil))
}
