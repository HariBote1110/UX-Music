package flac

import (
	"bytes"
	"testing"
)

func writeSubframeHeader(w *testBitWriter, typeCode uint64, wastedBits int) {
	w.writeBits(0, 1)      // padding
	w.writeBits(typeCode, 6)
	if wastedBits == 0 {
		w.writeBits(0, 1)
		return
	}
	w.writeBits(1, 1)
	w.writeUnary(uint32(wastedBits - 1))
}

func TestDecodeSubframe_Constant(t *testing.T) {
	var w testBitWriter
	writeSubframeHeader(&w, 0x00, 0)
	w.writeSigned(-42, 8)

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, 5)
	if err := decodeSubframe(br, 8, 5, out); err != nil {
		t.Fatalf("decodeSubframe failed: %v", err)
	}
	for i, v := range out {
		if v != -42 {
			t.Errorf("sample %d: got %d, want -42", i, v)
		}
	}
}

func TestDecodeSubframe_Verbatim(t *testing.T) {
	values := []int32{1, -2, 3, -4}
	var w testBitWriter
	writeSubframeHeader(&w, 0x01, 0)
	for _, v := range values {
		w.writeSigned(int64(v), 8)
	}

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, len(values))
	if err := decodeSubframe(br, 8, len(values), out); err != nil {
		t.Fatalf("decodeSubframe failed: %v", err)
	}
	for i, want := range values {
		if out[i] != want {
			t.Errorf("sample %d: got %d, want %d", i, out[i], want)
		}
	}
}

func TestDecodeSubframe_FixedOrder1(t *testing.T) {
	// warm-up s0=10, residuals [1,-2,3,-1] -> s = [10,11,9,12,11]
	want := []int32{10, 11, 9, 12, 11}
	residuals := []int32{1, -2, 3, -1}

	var w testBitWriter
	writeSubframeHeader(&w, 0x09, 0) // fixed, order 1
	w.writeSigned(10, 8)             // warm-up
	w.writeBits(0, 2)                // residual coding method 0
	w.writeBits(0, 4)                // partition order 0
	w.writeBits(3, 4)                // rice parameter 3
	for _, r := range residuals {
		w.writeRice(r, 3)
	}

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, len(want))
	if err := decodeSubframe(br, 8, len(want), out); err != nil {
		t.Fatalf("decodeSubframe failed: %v", err)
	}
	for i, wv := range want {
		if out[i] != wv {
			t.Errorf("sample %d: got %d, want %d", i, out[i], wv)
		}
	}
}

func TestDecodeSubframe_LPCOrder2(t *testing.T) {
	// coeffs = [1, 0], shift 0, precision 4 bits (code 3) -> predicts prior sample.
	// warm-up s0=5, s1=9; residuals [2,-3,5,-1] -> s = [5,9,11,8,13,12]
	want := []int32{5, 9, 11, 8, 13, 12}
	residuals := []int32{2, -3, 5, -1}

	var w testBitWriter
	writeSubframeHeader(&w, 0x21, 0) // LPC, order 2 (0x20 + (2-1))
	w.writeSigned(5, 8)              // warm-up s0
	w.writeSigned(9, 8)              // warm-up s1
	w.writeBits(3, 4)                // QLP precision code -> precision 4
	w.writeSigned(0, 5)              // shift 0
	w.writeSigned(1, 4)              // coeff 0 = 1
	w.writeSigned(0, 4)              // coeff 1 = 0
	w.writeBits(0, 2)                // residual method 0
	w.writeBits(0, 4)                // partition order 0
	w.writeBits(3, 4)                // rice parameter 3
	for _, r := range residuals {
		w.writeRice(r, 3)
	}

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, len(want))
	if err := decodeSubframe(br, 8, len(want), out); err != nil {
		t.Fatalf("decodeSubframe failed: %v", err)
	}
	for i, wv := range want {
		if out[i] != wv {
			t.Errorf("sample %d: got %d, want %d", i, out[i], wv)
		}
	}
}

func TestDecodeSubframe_WastedBits(t *testing.T) {
	// Constant subframe with 2 wasted bits: encoded value is right-shifted
	// by 2 before storage, so the decoded sample must be left-shifted back.
	var w testBitWriter
	writeSubframeHeader(&w, 0x00, 2)
	w.writeSigned(5, 6) // effective bits = 8 - 2 = 6

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, 3)
	if err := decodeSubframe(br, 8, 3, out); err != nil {
		t.Fatalf("decodeSubframe failed: %v", err)
	}
	for i, v := range out {
		if v != 5<<2 {
			t.Errorf("sample %d: got %d, want %d", i, v, 5<<2)
		}
	}
}

func TestDecodeSubframe_RejectsReservedType(t *testing.T) {
	var w testBitWriter
	writeSubframeHeader(&w, 0x02, 0) // reserved

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, 3)
	if err := decodeSubframe(br, 8, 3, out); err == nil {
		t.Fatal("expected an error for reserved subframe type code, got nil")
	}
}

func TestDecodeSubframe_RejectsOrderExceedingBlockSize(t *testing.T) {
	var w testBitWriter
	writeSubframeHeader(&w, 0x0C, 0) // fixed order 4

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, 2) // block size smaller than predictor order
	if err := decodeSubframe(br, 8, 2, out); err == nil {
		t.Fatal("expected an error for predictor order exceeding block size, got nil")
	}
}

func TestDecodeSubframe_RejectsNegativeLPCShift(t *testing.T) {
	var w testBitWriter
	writeSubframeHeader(&w, 0x20, 0) // LPC order 1
	w.writeSigned(1, 8)              // warm-up
	w.writeBits(0, 4)                // precision code 0 -> precision 1
	w.writeSigned(-1, 5)             // negative shift: invalid

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, 4)
	if err := decodeSubframe(br, 8, 4, out); err == nil {
		t.Fatal("expected an error for negative LPC shift, got nil")
	}
}
