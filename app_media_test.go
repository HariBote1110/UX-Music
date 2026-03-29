package main

import (
	"testing"
)

func TestNormalizeNowPlayingMetadata(t *testing.T) {
	tests := []struct {
		name       string
		title      string
		artist     string
		album      string
		wantTitle  string
		wantArtist string
		wantAlbum  string
	}{
		{
			name:       "all empty",
			title:      "",
			artist:     "",
			album:      "",
			wantTitle:  "UX-Music",
			wantArtist: "",
			wantAlbum:  "",
		},
		{
			name:       "whitespace only",
			title:      "   ",
			artist:     "\t",
			album:      "\n",
			wantTitle:  "UX-Music",
			wantArtist: "",
			wantAlbum:  "",
		},
		{
			name:       "normal strings",
			title:      "Song Title",
			artist:     "Artist Name",
			album:      "Album Name",
			wantTitle:  "Song Title",
			wantArtist: "Artist Name",
			wantAlbum:  "Album Name",
		},
		{
			name:       "strings with surrounding whitespace",
			title:      "  Song Title  ",
			artist:     "\tArtist Name\n",
			album:      " Album Name ",
			wantTitle:  "Song Title",
			wantArtist: "Artist Name",
			wantAlbum:  "Album Name",
		},
		{
			name:       "missing title but present artist/album",
			title:      "",
			artist:     "Artist Name",
			album:      "Album Name",
			wantTitle:  "UX-Music",
			wantArtist: "Artist Name",
			wantAlbum:  "Album Name",
		},
		{
			name:       "title present but missing artist/album",
			title:      "Song Title",
			artist:     "  ",
			album:      "",
			wantTitle:  "Song Title",
			wantArtist: "",
			wantAlbum:  "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotTitle, gotArtist, gotAlbum := normalizeNowPlayingMetadata(tt.title, tt.artist, tt.album)
			if gotTitle != tt.wantTitle {
				t.Errorf("normalizeNowPlayingMetadata() gotTitle = %v, want %v", gotTitle, tt.wantTitle)
			}
			if gotArtist != tt.wantArtist {
				t.Errorf("normalizeNowPlayingMetadata() gotArtist = %v, want %v", gotArtist, tt.wantArtist)
			}
			if gotAlbum != tt.wantAlbum {
				t.Errorf("normalizeNowPlayingMetadata() gotAlbum = %v, want %v", gotAlbum, tt.wantAlbum)
			}
		})
	}
}
