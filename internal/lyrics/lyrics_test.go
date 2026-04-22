package lyrics

import (
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/config"
)

func TestFindLyrics_includesTranslationWhenJaLrcPresent(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	if err := os.MkdirAll(filepath.Join(tmp, "Lyrics"), 0o755); err != nil {
		t.Fatal(err)
	}
	base := "Test Song"
	safe := SanitizeFileName(base)
	if err := os.WriteFile(
		filepath.Join(tmp, "Lyrics", safe+".lrc"),
		[]byte("[00:01.00]Hello\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(tmp, "Lyrics", safe+".ja.lrc"),
		[]byte("[00:01.00]こんにちは\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	got, err := FindLyrics(base)
	if err != nil {
		t.Fatalf("find: %v", err)
	}
	if got == nil {
		t.Fatal("expected result")
	}
	if got["type"] != "lrc" {
		t.Fatalf("type: got %q", got["type"])
	}
	if got["translationFormat"] != "lrc" {
		t.Fatalf("translationFormat: got %q", got["translationFormat"])
	}
	if got["translationContent"] != "[00:01.00]こんにちは\n" {
		t.Fatalf("translationContent: got %q", got["translationContent"])
	}
	if got["lyricsFileBase"] != safe {
		t.Fatalf("lyricsFileBase: got %q want %q", got["lyricsFileBase"], safe)
	}
}

func TestFindLyrics_jaTxtWhenNoJaLrc(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	if err := os.MkdirAll(filepath.Join(tmp, "Lyrics"), 0o755); err != nil {
		t.Fatal(err)
	}
	base := "Alpha"
	safe := SanitizeFileName(base)
	if err := os.WriteFile(
		filepath.Join(tmp, "Lyrics", safe+".lrc"),
		[]byte("[00:00.00]A\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(tmp, "Lyrics", safe+".ja.txt"),
		[]byte("あ\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	got, err := FindLyrics(base)
	if err != nil {
		t.Fatalf("find: %v", err)
	}
	if got["translationFormat"] != "txt" {
		t.Fatalf("translationFormat: got %q", got["translationFormat"])
	}
	if got["lyricsFileBase"] != safe {
		t.Fatalf("lyricsFileBase: got %q want %q", got["lyricsFileBase"], safe)
	}
}

func TestFindLyrics_jaLrcTakesPrecedenceOverJaTxt(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	if err := os.MkdirAll(filepath.Join(tmp, "Lyrics"), 0o755); err != nil {
		t.Fatal(err)
	}
	base := "Beta"
	safe := SanitizeFileName(base)
	if err := os.WriteFile(
		filepath.Join(tmp, "Lyrics", safe+".lrc"),
		[]byte("[00:00.00]A\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(tmp, "Lyrics", safe+".ja.lrc"),
		[]byte("[00:00.00]あ\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(tmp, "Lyrics", safe+".ja.txt"),
		[]byte("い\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}
	got, err := FindLyrics(base)
	if err != nil {
		t.Fatalf("find: %v", err)
	}
	if got["translationFormat"] != "lrc" {
		t.Fatalf("expected ja.lrc to win, got %q", got["translationFormat"])
	}
}

func TestSaveLrcFile_acceptsJaTxtAndJaLrc(t *testing.T) {
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	lyricsDir := filepath.Join(tmp, "Lyrics")
	if err := os.MkdirAll(lyricsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := SaveLrcFile("Side.ja.txt", "あ\nい\n"); err != nil {
		t.Fatalf("ja.txt: %v", err)
	}
	if err := SaveLrcFile("Side.ja.lrc", "[00:00.00]あ\n"); err != nil {
		t.Fatalf("ja.lrc: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(lyricsDir, "Side.ja.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "あ\nい\n" {
		t.Fatalf("ja.txt: got %q", b)
	}
}

func TestSaveLrcFile_rejectsArbitraryTxt(t *testing.T) {
	if err := SaveLrcFile("nope.txt", "x"); err == nil {
		t.Fatal("expected error for .txt")
	}
}
