package lyricssync

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
	"golang.org/x/text/width"
)

func normaliseText(raw string) string {
	text := norm.NFC.String(raw)
	text = width.Fold.String(text)
	text = strings.ToLower(strings.TrimSpace(text))

	var b strings.Builder
	for _, r := range text {
		if unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r) {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

func isInterludeLine(text string) bool {
	normalised := strings.TrimSpace(strings.ToLower(width.Fold.String(norm.NFC.String(text))))
	return normalised == "" ||
		normalised == "[間奏]" ||
		normalised == "[interlude]" ||
		normalised == "(interlude)"
}
