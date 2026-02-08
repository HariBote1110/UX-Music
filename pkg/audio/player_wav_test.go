package audio

import "testing"

func TestWavSampleToInt16_8bitUnsigned(t *testing.T) {
	if got := wavSampleToInt16(0, 8); got != -32768 {
		t.Fatalf("expected -32768, got %d", got)
	}
	if got := wavSampleToInt16(128, 8); got != 0 {
		t.Fatalf("expected 0, got %d", got)
	}
	if got := wavSampleToInt16(255, 8); got != 32512 {
		t.Fatalf("expected 32512, got %d", got)
	}
}

func TestWavSampleToInt16_24bitScaling(t *testing.T) {
	if got := wavSampleToInt16(8388607, 24); got != 32767 {
		t.Fatalf("expected 32767, got %d", got)
	}
	if got := wavSampleToInt16(-8388608, 24); got != -32768 {
		t.Fatalf("expected -32768, got %d", got)
	}
	if got := wavSampleToInt16(0, 24); got != 0 {
		t.Fatalf("expected 0, got %d", got)
	}
}
