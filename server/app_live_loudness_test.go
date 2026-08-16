package server

import (
	"math"
	"testing"
)

// 目標ラウドネスは設定から渡ってくるため、壊れた値でも 0 LUFS（= フルスケール）
// のような危険な値へ落ちないこと。
func TestSanitiseTargetLoudness(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input float64
		want  float64
	}{
		{"通常の設定値", -18, -18},
		{"NaN は既定値", math.NaN(), -18},
		{"Inf は既定値", math.Inf(1), -18},
		{"ゼロは既定値（未設定とみなす）", 0, -18},
		{"正の値は既定値", 3, -18},
		{"下限より小さい値は既定値", -80, -18},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := sanitiseTargetLoudness(tc.input); got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}
