package normalize

import (
	"regexp"
	"testing"
)

var testOutput = `
[Parsed_volumedetect_0 @ 0x7f8a8b80] mean_volume: -20.5 dB
[Parsed_volumedetect_0 @ 0x7f8a8b80] max_volume: -1.2 dB
`

func BenchmarkRegexInside(b *testing.B) {
	for i := 0; i < b.N; i++ {
		meanRe := regexp.MustCompile(`mean_volume:\s*(-?\d+\.\d+)\s*dB`)
		maxRe := regexp.MustCompile(`max_volume:\s*(-?\d+\.\d+)\s*dB`)

		_ = meanRe.FindStringSubmatch(testOutput)
		_ = maxRe.FindStringSubmatch(testOutput)
	}
}

var (
	meanReGlob = regexp.MustCompile(`mean_volume:\s*(-?\d+\.\d+)\s*dB`)
	maxReGlob  = regexp.MustCompile(`max_volume:\s*(-?\d+\.\d+)\s*dB`)
)

func BenchmarkRegexOutside(b *testing.B) {
	for i := 0; i < b.N; i++ {
		_ = meanReGlob.FindStringSubmatch(testOutput)
		_ = maxReGlob.FindStringSubmatch(testOutput)
	}
}
