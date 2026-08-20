package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ux-music-sidecar/pkg/playqueue"
)

func TestDispatchOSMediaCommand_QueueInactive_EmitsLegacyEvent(t *testing.T) {
	app, emitted := newRemoteCommandTestApp(t)
	app.ctx = context.Background()

	app.dispatchOSMediaCommand("next")

	if len(*emitted) != 1 || (*emitted)[0].name != "os-media-command" || (*emitted)[0].data != "next" {
		t.Fatalf("expected single os-media-command(next) emit, got %#v", *emitted)
	}
}

func TestDispatchOSMediaCommand_QueueActive_NextPrevHandledInGo(t *testing.T) {
	newTempUserDataStore(t)
	app, emitted := newRemoteCommandTestApp(t)
	app.ctx = context.Background()
	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
	}, 0)
	*emitted = nil

	app.dispatchOSMediaCommand("next")

	for _, e := range *emitted {
		if e.name == "os-media-command" {
			t.Fatalf("os-media-command must not be emitted for next/previous once the Go queue is active, got %#v", *emitted)
		}
	}
	current, ok := app.ensureQueue().CurrentItem()
	if !ok || current.ID != "b" {
		t.Fatalf("CurrentItem() after dispatchOSMediaCommand(next) = %+v, %v; want b, true", current, ok)
	}
}

func TestDispatchOSMediaCommand_QueueActive_OtherCommandsStillEmit(t *testing.T) {
	newTempUserDataStore(t)
	app, emitted := newRemoteCommandTestApp(t)
	app.ctx = context.Background()
	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
	}, 0)
	*emitted = nil

	app.dispatchOSMediaCommand("toggle")

	if len(*emitted) != 1 || (*emitted)[0].name != "os-media-command" || (*emitted)[0].data != "toggle" {
		t.Fatalf("expected toggle to still be forwarded to the renderer even with an active queue, got %#v", *emitted)
	}
}

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

func TestResolveNowPlayingArtworkPath(t *testing.T) {
	// テスト用の一時 userDataPath。以前は os.MkdirTemp + os.RemoveAll で
	// ディレクトリだけ消し、プロセスグローバルの config は削除済みパスを
	// 指したまま残していたため、後続テストが実行順によって壊れていた。
	tmpDir := newTempUserDataStore(t)

	artworksDir := filepath.Join(tmpDir, "Artworks")
	if err := os.Mkdir(artworksDir, 0755); err != nil {
		t.Fatalf("Failed to create Artworks dir: %v", err)
	}

	validRelativeImage := "test-image.jpg"
	validRelativeImagePath := filepath.Join(artworksDir, validRelativeImage)
	if err := os.WriteFile(validRelativeImagePath, []byte("dummy data"), 0644); err != nil {
		t.Fatalf("Failed to create dummy image: %v", err)
	}
	cleanValidRelativeImagePath := filepath.Clean(validRelativeImagePath)

	validAbsoluteImage := filepath.Join(tmpDir, "absolute-image.jpg")
	if err := os.WriteFile(validAbsoluteImage, []byte("dummy data"), 0644); err != nil {
		t.Fatalf("Failed to create dummy absolute image: %v", err)
	}
	cleanValidAbsoluteImage := filepath.Clean(validAbsoluteImage)

	tests := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "empty string",
			raw:  "",
			want: "",
		},
		{
			name: "whitespace string",
			raw:  "   ",
			want: "",
		},
		{
			name: "http url",
			raw:  "http://example.com/image.jpg",
			want: "",
		},
		{
			name: "https url",
			raw:  "https://example.com/image.jpg",
			want: "",
		},
		{
			name: "data uri",
			raw:  "data:image/jpeg;base64,123",
			want: "",
		},
		{
			name: "blob uri",
			raw:  "blob:http://localhost/123",
			want: "",
		},
		{
			name: "safe-artwork with valid relative image",
			raw:  "safe-artwork://" + validRelativeImage,
			want: cleanValidRelativeImagePath,
		},
		{
			name: "safe-artwork with single slash",
			raw:  "safe-artwork/" + validRelativeImage,
			want: cleanValidRelativeImagePath,
		},
		{
			name: "safe-artwork with leading slash",
			raw:  "/safe-artwork/" + validRelativeImage,
			want: cleanValidRelativeImagePath,
		},
		{
			name: "url encoded safe-artwork",
			raw:  "safe-artwork://" + strings.ReplaceAll(validRelativeImage, "-", "%2D"),
			want: cleanValidRelativeImagePath,
		},
		{
			name: "absolute path existing",
			raw:  validAbsoluteImage,
			want: cleanValidAbsoluteImage,
		},
		{
			name: "absolute path non-existing",
			raw:  filepath.Join(tmpDir, "non-existing.jpg"),
			want: "",
		},
		{
			name: "relative traversal out of directory",
			raw:  "safe-artwork://../absolute-image.jpg",
			want: "",
		},
		{
			name: "relative traversal root",
			raw:  "..",
			want: "",
		},
		{
			name: "relative traversal current dir",
			raw:  ".",
			want: "",
		},
		{
			name: "non-existent relative image",
			raw:  "non-existent.jpg",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := resolveNowPlayingArtworkPath(tt.raw)
			if got != tt.want {
				t.Errorf("resolveNowPlayingArtworkPath(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}
