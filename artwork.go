package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/dhowden/tag"
	// このパッケージはデコード用。エンコードには外部ツールか別ライブラリが必要
)

// NOTE: Go標準ライブラリにはWebPエンコーダが含まれていないため、
// 長期的には並列処理に強い外部ライブラリか、ffmpeg を使用した変換を検討します。
// 今回は、まず Go 側でアートワークを抽出して保存する枠組みを作ります。

func extractAndSaveArtwork(songPath string, artworksDir string) (interface{}, error) {
	f, err := os.Open(songPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	m, err := tag.ReadFrom(f)
	if err != nil {
		return nil, err
	}

	p := m.Picture()
	if p == nil {
		return nil, nil
	}

	// アルバム固有のハッシュを作成
	albumArtist := m.AlbumArtist()
	if albumArtist == "" {
		albumArtist = m.Artist()
	}
	albumTitle := m.Album()
	uniqueKey := fmt.Sprintf("%s---%s", albumArtist, albumTitle)
	hash := fmt.Sprintf("%x", sha256.Sum256([]byte(uniqueKey)))

	fullFileName := hash + ".webp"
	thumbFileName := hash + "_thumb.webp"
	fullPath := filepath.Join(artworksDir, fullFileName)
	thumbPath := filepath.Join(artworksDir, "thumbnails", thumbFileName)

	// 既に存在する場合はスキップ (フルサイズが存在すればサムネイルもあると仮定)
	if _, err := os.Stat(fullPath); err == nil {
		return map[string]string{
			"full":      fullFileName,
			"thumbnail": thumbFileName,
		}, nil
	}

	// ディレクトリ作成
	os.MkdirAll(filepath.Join(artworksDir, "thumbnails"), 0755)

	// ffmpeg を使用して WebP に変換 (フルサイズ)
	if err := convertToWebP(p.Data, fullPath, 0); err != nil {
		return nil, fmt.Errorf("failed to convert full artwork: %v", err)
	}

	// ffmpeg を使用して WebP に変換 (サムネイル - 200px)
	if err := convertToWebP(p.Data, thumbPath, 200); err != nil {
		// サムネイル失敗は致命的ではないがログには出す
		fmt.Printf("[Artwork] Warning: failed to create thumbnail: %v\n", err)
	}

	return map[string]string{
		"full":      fullFileName,
		"thumbnail": thumbFileName,
	}, nil
}

func convertToWebP(data []byte, outputPath string, width int) error {
	if FFmpegPath == "" {
		return fmt.Errorf("ffmpeg path not set")
	}

	args := []string{"-i", "pipe:0"}
	if width > 0 {
		args = append(args, "-vf", fmt.Sprintf("scale=%d:-1", width))
	}
	// -q:v 80 で品質設定, -y で上書き
	args = append(args, "-c:v", "webp", "-q:v", "80", "-y", outputPath)

	cmd := exec.Command(FFmpegPath, args...)
	cmd.Stdin = bytes.NewReader(data)

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg error: %v, stderr: %s", err, stderr.String())
	}

	return nil
}
