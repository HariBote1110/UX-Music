package lyrics

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"ux-music-sidecar/internal/config"
)

var invalidCharsRe = regexp.MustCompile(`[<>:"/\\|?*]`)

// SanitizeFileName converts invalid characters to underscores
func SanitizeFileName(name string) string {
	return invalidCharsRe.ReplaceAllString(name, "_")
}

func GetLyricsDir() string {
	dir := filepath.Join(config.GetUserDataPath(), "Lyrics")
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		os.MkdirAll(dir, 0755)
	}
	return dir
}

func FindLyrics(targetName string) (map[string]string, error) {
	lyricsDir := GetLyricsDir()
	sanitizedBase := SanitizeFileName(strings.ReplaceAll(targetName, "_", " "))

	// readErr remembers the first read failure on an existing file. A failed
	// .lrc still falls through to .txt, but if nothing else is readable the
	// failure is reported instead of being mistaken for "no lyrics".
	var readErr error

	// Check .lrc
	lrcPath := filepath.Join(lyricsDir, sanitizedBase+".lrc")
	if _, err := os.Stat(lrcPath); err == nil {
		content, err := os.ReadFile(lrcPath)
		if err == nil {
			return attachJaTranslation(lyricsDir, sanitizedBase, "lrc", string(content))
		}
		readErr = fmt.Errorf("failed to read lyrics file %q: %w", lrcPath, err)
	}

	// Check .txt
	txtPath := filepath.Join(lyricsDir, sanitizedBase+".txt")
	if _, err := os.Stat(txtPath); err == nil {
		content, err := os.ReadFile(txtPath)
		if err == nil {
			return attachJaTranslation(lyricsDir, sanitizedBase, "txt", string(content))
		}
		if readErr == nil {
			readErr = fmt.Errorf("failed to read lyrics file %q: %w", txtPath, err)
		}
	}

	if readErr != nil {
		return nil, readErr
	}
	return nil, nil // Not found
}

// attachJaTranslation adds optional {base}.ja.lrc (preferred) or {base}.ja.txt when present.
func attachJaTranslation(lyricsDir, sanitizedBase, mainType, mainContent string) (map[string]string, error) {
	res := map[string]string{
		"type":            mainType,
		"content":         mainContent,
		"lyricsFileBase": sanitizedBase,
	}
	// A translation that cannot be read never fails the call: an unreadable
	// .ja.lrc falls through to .ja.txt, and main lyrics are still returned.
	jaLrc := filepath.Join(lyricsDir, sanitizedBase+".ja.lrc")
	if st, err := os.Stat(jaLrc); err == nil && !st.IsDir() {
		if b, err := os.ReadFile(jaLrc); err == nil {
			if strings.TrimSpace(string(b)) != "" {
				res["translationContent"] = string(b)
				res["translationFormat"] = "lrc"
			}
			return res, nil
		}
	}
	jaTxt := filepath.Join(lyricsDir, sanitizedBase+".ja.txt")
	if st, err := os.Stat(jaTxt); err == nil && !st.IsDir() {
		if b, err := os.ReadFile(jaTxt); err == nil {
			if strings.TrimSpace(string(b)) != "" {
				res["translationContent"] = string(b)
				res["translationFormat"] = "txt"
			}
		}
	}
	return res, nil
}

func allowedUserLyricsFileName(name string) bool {
	lower := strings.ToLower(filepath.Base(name))
	if strings.HasSuffix(lower, ".ja.txt") {
		return true
	}
	// Includes standard .lrc and bilingual .ja.lrc (suffix .lrc).
	if strings.HasSuffix(lower, ".lrc") {
		return true
	}
	return false
}

// SaveLrcFile writes a file under the user Lyrics directory. Allowed names: *.lrc, *.ja.lrc, *.ja.txt
func SaveLrcFile(fileName string, content string) error {
	lyricsDir := GetLyricsDir()

	if !allowedUserLyricsFileName(fileName) {
		return fmt.Errorf("file name must end with .lrc, .ja.lrc, or .ja.txt")
	}

	safeName := SanitizeFileName(fileName)
	path := filepath.Join(lyricsDir, safeName)

	return os.WriteFile(path, []byte(content), 0644)
}

func CopyLyricsFiles(srcPaths []string) (int, error) {
	lyricsDir := GetLyricsDir()
	count := 0

	for _, srcPath := range srcPaths {
		fileName := filepath.Base(srcPath)
		destPath := filepath.Join(lyricsDir, fileName)

		srcFile, err := os.Open(srcPath)
		if err != nil {
			continue
		}

		destFile, err := os.Create(destPath)
		if err != nil {
			srcFile.Close()
			continue
		}

		_, err = io.Copy(destFile, srcFile)

		srcFile.Close()
		destFile.Close()

		if err == nil {
			count++
		}
	}

	return count, nil
}
