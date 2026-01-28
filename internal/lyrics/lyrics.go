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

// SanitizeFileName converts invalid characters to underscores
func SanitizeFileName(name string) string {
	re := regexp.MustCompile(`[<>:"/\\|?*]`)
	return re.ReplaceAllString(name, "_")
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

	// Check .lrc
	lrcPath := filepath.Join(lyricsDir, sanitizedBase+".lrc")
	if _, err := os.Stat(lrcPath); err == nil {
		content, err := os.ReadFile(lrcPath)
		if err == nil {
			return map[string]string{"type": "lrc", "content": string(content)}, nil
		}
	}

	// Check .txt
	txtPath := filepath.Join(lyricsDir, sanitizedBase+".txt")
	if _, err := os.Stat(txtPath); err == nil {
		content, err := os.ReadFile(txtPath)
		if err == nil {
			return map[string]string{"type": "txt", "content": string(content)}, nil
		}
	}

	return nil, nil // Not found
}

func SaveLrcFile(fileName string, content string) error {
	lyricsDir := GetLyricsDir()

	if !strings.HasSuffix(strings.ToLower(fileName), ".lrc") {
		return fmt.Errorf("file extension must be .lrc")
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
