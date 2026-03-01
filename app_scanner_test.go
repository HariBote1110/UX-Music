package main

import (
	"reflect"
	"testing"

	"ux-music-sidecar/internal/scanner"
)

func TestSortSongsForLibraryOrdersByAlbumDiscTrack(t *testing.T) {
	songs := []scanner.Song{
		{
			Path:        "/music/A/Album/03-second.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 3,
			Title:       "Second",
		},
		{
			Path:        "/music/A/Album/01-first.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 1,
			Title:       "First",
		},
		{
			Path:        "/music/A/Album/201-disc2.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  2,
			TrackNumber: 1,
			Title:       "Disc2 First",
		},
	}

	sortSongsForLibrary(songs)

	got := []string{songs[0].Path, songs[1].Path, songs[2].Path}
	want := []string{
		"/music/A/Album/01-first.flac",
		"/music/A/Album/03-second.flac",
		"/music/A/Album/201-disc2.flac",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sortSongsForLibrary() order = %#v, want %#v", got, want)
	}
}

func TestSortSongsForLibraryUnknownTrackFallsBackToTitleAndPath(t *testing.T) {
	songs := []scanner.Song{
		{
			Path:        "/music/A/Album/z-last.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 0,
			Title:       "Zeta",
		},
		{
			Path:        "/music/A/Album/a-first.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 0,
			Title:       "Alpha",
		},
		{
			Path:        "/music/A/Album/02-known.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 2,
			Title:       "Known",
		},
	}

	sortSongsForLibrary(songs)

	got := []string{songs[0].Path, songs[1].Path, songs[2].Path}
	want := []string{
		"/music/A/Album/02-known.flac",
		"/music/A/Album/a-first.flac",
		"/music/A/Album/z-last.flac",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sortSongsForLibrary() fallback order = %#v, want %#v", got, want)
	}
}
