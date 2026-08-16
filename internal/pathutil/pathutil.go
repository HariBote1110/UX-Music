// Package pathutil centralises file path canonicalisation helpers
// (filepath.Clean and Unicode NFC/NFD normalisation) that were previously
// duplicated across server/ handlers.
package pathutil

import (
	"path/filepath"
	"strings"

	"golang.org/x/text/unicode/norm"
)

// CanonicalisePath returns the cleaned, NFC-normalised form of path.
// An empty input yields an empty string.
func CanonicalisePath(path string) string {
	if path == "" {
		return ""
	}
	return norm.NFC.String(filepath.Clean(path))
}

// NFC returns the NFC-normalised form of s.
func NFC(s string) string {
	return norm.NFC.String(s)
}

// CandidateForms returns lookup candidates for a stored path key: the
// trimmed input, its cleaned form, and the NFC/NFD normalised variants of
// the cleaned form, deduplicated in that order. A blank input yields nil.
func CandidateForms(path string) []string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return nil
	}

	cleaned := filepath.Clean(trimmed)
	nfc := norm.NFC.String(cleaned)
	nfd := norm.NFD.String(cleaned)

	return dedupeNonEmpty([]string{trimmed, cleaned, nfc, nfd})
}

// SlashCandidateForms returns lookup candidates for a path that may be
// stored with either native or forward-slash separators: the raw path, its
// cleaned form, the slash form and the cleaned slash form, deduplicated.
func SlashCandidateForms(path string) []string {
	if path == "" {
		return nil
	}
	return dedupeNonEmpty([]string{
		path,
		filepath.Clean(path),
		filepath.ToSlash(path),
		filepath.Clean(filepath.ToSlash(path)),
	})
}

// SamePath reports whether two paths refer to the same location after
// absolutisation and cleaning. If absolutisation fails, cleaned forms are
// compared directly.
func SamePath(aPath, bPath string) bool {
	aAbs, aErr := filepath.Abs(aPath)
	bAbs, bErr := filepath.Abs(bPath)
	if aErr != nil || bErr != nil {
		return filepath.Clean(aPath) == filepath.Clean(bPath)
	}
	return filepath.Clean(aAbs) == filepath.Clean(bAbs)
}

func dedupeNonEmpty(candidates []string) []string {
	result := make([]string, 0, len(candidates))
	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}
		result = append(result, candidate)
	}
	return result
}
