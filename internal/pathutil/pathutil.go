// Package pathutil centralises file path canonicalisation helpers
// (filepath.Clean and Unicode NFC/NFD normalisation) that were previously
// duplicated across server/ handlers.
package pathutil

import (
	stdpath "path"
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

// toSlashForm returns path with backslashes rewritten to forward slashes,
// independent of the OS this process runs on.
//
// filepath.ToSlash is NOT sufficient here: it only rewrites the *current*
// OS's filepath.Separator, so on macOS/Linux (Separator == '/') it leaves a
// Windows-authored, backslash-separated path untouched. library.json is a
// portable file that may be opened on a different OS than the one that
// wrote it, so separator normalisation must not depend on the runtime OS.
func toSlashForm(path string) string {
	return strings.ReplaceAll(path, "\\", "/")
}

// CandidateForms returns lookup candidates for a stored path key: the
// trimmed input, its OS-native cleaned form, its OS-independent slash form,
// and the NFC/NFD normalised variants of both, deduplicated in that order.
// A blank input yields nil.
//
// Both the native and slash forms are needed because a path key may have
// been written by either a POSIX (macOS/Linux) or a Windows build of this
// app: filepath.Clean always emits the *current* OS's separator regardless
// of the input's separator style, so relying on it alone silently drops the
// candidate a cross-platform-authored library actually needs (see
// TestCandidateFormsResolvesAcrossPlatforms).
func CandidateForms(path string) []string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return nil
	}

	cleaned := filepath.Clean(trimmed)
	slash := stdpath.Clean(toSlashForm(trimmed))

	return dedupeNonEmpty([]string{
		trimmed,
		cleaned,
		slash,
		norm.NFC.String(cleaned),
		norm.NFD.String(cleaned),
		norm.NFC.String(slash),
		norm.NFD.String(slash),
	})
}

// SlashCandidateForms returns lookup candidates for a path that may be
// stored with either native or forward-slash separators: the raw path, its
// OS-native cleaned form, the slash form and the cleaned slash form,
// deduplicated.
//
// The cleaned slash form uses path.Clean (always "/"-based), not
// filepath.Clean(toSlashForm(path)): filepath.Clean re-emits the current
// OS's separator regardless of its input, so on Windows that combination
// silently turned the "slash form" back into a backslash form and defeated
// its purpose (see TestSlashCandidateFormsResolvesAcrossPlatforms).
func SlashCandidateForms(path string) []string {
	if path == "" {
		return nil
	}
	slash := toSlashForm(path)
	return dedupeNonEmpty([]string{
		path,
		filepath.Clean(path),
		slash,
		stdpath.Clean(slash),
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
