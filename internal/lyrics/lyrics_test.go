package lyrics

import (
	"os"
	"path/filepath"
	"runtime"
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

// setupLyricsTestDir points the user data path at a temp dir and returns its Lyrics directory.
func setupLyricsTestDir(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(tmp)
	t.Cleanup(func() { config.SetUserDataPath(prev) })
	dir := filepath.Join(tmp, "Lyrics")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

// writeUnreadableFile creates path and makes it unreadable, skipping where
// permission bits do not restrict reads (root, Windows).
func writeUnreadableFile(t *testing.T, path string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("file permission bits do not block reads on Windows")
	}
	if os.Geteuid() == 0 {
		t.Skip("root ignores file permission bits")
	}
	if err := os.WriteFile(path, []byte("[00:01.00]secret\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
	if _, err := os.ReadFile(path); err == nil {
		t.Skip("filesystem still allows reading a mode 0000 file")
	}
}

func TestFindLyrics_unreadableLrcFallsBackToTxt(t *testing.T) {
	dir := setupLyricsTestDir(t)
	base := SanitizeFileName("Fallback Song")
	writeUnreadableFile(t, filepath.Join(dir, base+".lrc"))
	txtBody := "plain lyrics\n"
	if err := os.WriteFile(filepath.Join(dir, base+".txt"), []byte(txtBody), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := FindLyrics("Fallback Song")
	if err != nil {
		t.Fatalf("FindLyrics: unexpected error %v", err)
	}
	if got == nil || got["type"] != "txt" || got["content"] != txtBody {
		t.Fatalf("FindLyrics = %#v; want the txt fallback", got)
	}
}

func TestFindLyrics_unreadableLrcWithoutFallbackReturnsError(t *testing.T) {
	dir := setupLyricsTestDir(t)
	base := SanitizeFileName("Locked Song")
	writeUnreadableFile(t, filepath.Join(dir, base+".lrc"))

	got, err := FindLyrics("Locked Song")
	if err == nil {
		t.Fatalf("FindLyrics = %#v, nil; want a read error", got)
	}
	if got != nil {
		t.Fatalf("FindLyrics returned content %#v alongside error", got)
	}
}

func TestFindLyrics_absentFilesStillReturnNil(t *testing.T) {
	setupLyricsTestDir(t)
	got, err := FindLyrics("Nothing Here")
	if err != nil || got != nil {
		t.Fatalf("FindLyrics = %#v, %v; want nil, nil", got, err)
	}
}

func TestFindLyrics_unreadableJaLrcFallsBackToJaTxt(t *testing.T) {
	dir := setupLyricsTestDir(t)
	base := SanitizeFileName("Bilingual Song")
	if err := os.WriteFile(filepath.Join(dir, base+".lrc"), []byte("[00:01.00]Hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeUnreadableFile(t, filepath.Join(dir, base+".ja.lrc"))
	jaBody := "こんにちは\n"
	if err := os.WriteFile(filepath.Join(dir, base+".ja.txt"), []byte(jaBody), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := FindLyrics("Bilingual Song")
	if err != nil {
		t.Fatalf("FindLyrics: %v", err)
	}
	if got == nil || got["content"] != "[00:01.00]Hello\n" {
		t.Fatalf("main lyrics lost: %#v", got)
	}
	if got["translationContent"] != jaBody || got["translationFormat"] != "txt" {
		t.Fatalf("expected ja.txt translation after unreadable ja.lrc, got %#v", got)
	}
}

func TestFindLyrics_unreadableJaLrcWithoutFallbackKeepsMainLyrics(t *testing.T) {
	dir := setupLyricsTestDir(t)
	base := SanitizeFileName("Solo Translation Song")
	if err := os.WriteFile(filepath.Join(dir, base+".lrc"), []byte("[00:01.00]Hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeUnreadableFile(t, filepath.Join(dir, base+".ja.lrc"))

	got, err := FindLyrics("Solo Translation Song")
	if err != nil {
		t.Fatalf("translation read failure must not fail the call: %v", err)
	}
	if got == nil || got["content"] != "[00:01.00]Hello\n" {
		t.Fatalf("main lyrics missing: %#v", got)
	}
	if _, ok := got["translationContent"]; ok {
		t.Fatalf("unexpected translation: %#v", got)
	}
}

func TestFindLyrics_blankReadableJaLrcSuppressesJaTxt(t *testing.T) {
	dir := setupLyricsTestDir(t)
	base := SanitizeFileName("Blank Translation Song")
	if err := os.WriteFile(filepath.Join(dir, base+".lrc"), []byte("[00:01.00]Hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, base+".ja.lrc"), []byte("  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, base+".ja.txt"), []byte("こんにちは\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	got, err := FindLyrics("Blank Translation Song")
	if err != nil {
		t.Fatalf("FindLyrics: %v", err)
	}
	if _, ok := got["translationContent"]; ok {
		t.Fatalf("blank ja.lrc must not fall through to ja.txt: %#v", got)
	}
}

func TestCopyLyricsFiles_copiesOnlyLyricsFilesAndSkipsOthers(t *testing.T) {
	dir := setupLyricsTestDir(t)
	src := t.TempDir()
	for name, body := range map[string]string{
		"song.lrc":    "[00:01.00]a\n",
		"song.ja.txt": "b\n",
		"UPPER.LRC":   "[00:02.00]c\n",
		"notes.pdf":   "pdf",
		"run.sh":      "echo hi",
	} {
		if err := os.WriteFile(filepath.Join(src, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(src, "folder.lrc"), 0o755); err != nil {
		t.Fatal(err)
	}

	srcPaths := []string{
		filepath.Join(src, "song.lrc"),
		filepath.Join(src, "song.ja.txt"),
		filepath.Join(src, "UPPER.LRC"),
		filepath.Join(src, "notes.pdf"),
		filepath.Join(src, "run.sh"),
		filepath.Join(src, "folder.lrc"),
	}
	count, err := CopyLyricsFiles(srcPaths)
	if err != nil {
		t.Fatalf("CopyLyricsFiles: %v", err)
	}
	wantCount := 3
	if count != wantCount {
		t.Fatalf("count = %d; want %d", count, wantCount)
	}
	for _, name := range []string{"song.lrc", "song.ja.txt", "UPPER.LRC"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Fatalf("expected %s copied: %v", name, err)
		}
	}
	for _, name := range []string{"notes.pdf", "run.sh", "folder.lrc"} {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("%s should not be copied (stat err=%v)", name, err)
		}
	}
}

func TestCopyLyricsFiles_sameNameOverwritesWithoutLeftoverTemp(t *testing.T) {
	dir := setupLyricsTestDir(t)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "song.lrc"), []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}
	newBody := "[00:03.00]new\n"
	srcFile := filepath.Join(src, "song.lrc")
	if err := os.WriteFile(srcFile, []byte(newBody), 0o644); err != nil {
		t.Fatal(err)
	}

	count, err := CopyLyricsFiles([]string{srcFile})
	if err != nil || count != 1 {
		t.Fatalf("CopyLyricsFiles = %d, %v; want 1, nil", count, err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "song.lrc"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != newBody {
		t.Fatalf("destination = %q; want %q", got, newBody)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("expected only song.lrc in Lyrics dir, got %v", names)
	}
}

func TestCopyLyricsFiles_unreadableSourceKeepsExistingDestination(t *testing.T) {
	dir := setupLyricsTestDir(t)
	src := t.TempDir()
	oldBody := "old lyrics"
	if err := os.WriteFile(filepath.Join(dir, "keep.lrc"), []byte(oldBody), 0o644); err != nil {
		t.Fatal(err)
	}
	srcFile := filepath.Join(src, "keep.lrc")
	writeUnreadableFile(t, srcFile)

	count, err := CopyLyricsFiles([]string{srcFile})
	if err != nil {
		t.Fatalf("CopyLyricsFiles: %v", err)
	}
	if count != 0 {
		t.Fatalf("count = %d; want 0 for unreadable source", count)
	}
	got, err := os.ReadFile(filepath.Join(dir, "keep.lrc"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != oldBody {
		t.Fatalf("existing destination changed to %q", got)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("temp file left behind: %d entries", len(entries))
	}
}
