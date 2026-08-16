package flac

import (
	"bytes"
	"testing"
)

// TestDecodeResidual_SinglePartitionRice constructs a hand-encoded residual
// block with one partition (order 0), coding method 0 (4-bit parameter),
// Rice parameter 2, and asserts the decoded values match what was encoded.
func TestDecodeResidual_SinglePartitionRice(t *testing.T) {
	const predictorOrder = 2
	const blockSize = 8
	values := []int32{-3, 5, 0, 1, -1, 7} // blockSize - predictorOrder values

	var w testBitWriter
	w.writeBits(0, 2)  // coding method 0
	w.writeBits(0, 4)  // partition order 0 -> 1 partition
	w.writeBits(2, 4)  // rice parameter 2
	for _, v := range values {
		w.writeRice(v, 2)
	}

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, blockSize)
	if err := decodeResidual(br, blockSize, predictorOrder, out); err != nil {
		t.Fatalf("decodeResidual failed: %v", err)
	}
	for i, want := range values {
		if got := out[predictorOrder+i]; got != want {
			t.Errorf("sample %d: got %d, want %d", i, got, want)
		}
	}
}

// TestDecodeResidual_MultiPartition exercises multiple partitions (order 2)
// with method 1 (5-bit parameter), each with a different Rice parameter.
func TestDecodeResidual_MultiPartition(t *testing.T) {
	const predictorOrder = 1
	const blockSize = 16
	const partitionOrder = 2 // 4 partitions of 4 samples each
	partitions := [][]int32{
		{1, -1, 2, -2}, // first partition is short by predictorOrder -> 3 values used
		{10, -10, 20, -20},
		{100, -100, 50, -50},
		{0, 0, 0, 1},
	}
	params := []uint{1, 3, 5, 0}

	var w testBitWriter
	w.writeBits(1, 2) // coding method 1
	w.writeBits(partitionOrder, 4)
	var want []int32
	for p := 0; p < 4; p++ {
		w.writeBits(uint64(params[p]), 5)
		vals := partitions[p]
		start := 0
		if p == 0 {
			start = predictorOrder
		}
		for _, v := range vals[start:] {
			w.writeRice(v, params[p])
			want = append(want, v)
		}
	}

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, blockSize)
	if err := decodeResidual(br, blockSize, predictorOrder, out); err != nil {
		t.Fatalf("decodeResidual failed: %v", err)
	}
	for i, wv := range want {
		if got := out[predictorOrder+i]; got != wv {
			t.Errorf("sample %d: got %d, want %d", i, got, wv)
		}
	}
}

// TestDecodeResidual_Escape exercises the escape code (all-ones Rice
// parameter), including the width-0 all-zero case.
func TestDecodeResidual_Escape(t *testing.T) {
	const predictorOrder = 0
	const blockSize = 4
	values := []int32{-5, 3, -8, 7}

	var w testBitWriter
	w.writeBits(0, 2) // method 0
	w.writeBits(0, 4) // partition order 0
	w.writeBits(riceEscapeParam4, 4)
	w.writeBits(5, 5) // 5-bit unencoded width
	for _, v := range values {
		w.writeSigned(int64(v), 5)
	}

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, blockSize)
	if err := decodeResidual(br, blockSize, predictorOrder, out); err != nil {
		t.Fatalf("decodeResidual failed: %v", err)
	}
	for i, want := range values {
		if got := out[i]; got != want {
			t.Errorf("sample %d: got %d, want %d", i, got, want)
		}
	}
}

// TestDecodeResidual_EscapeZeroWidth exercises the width-0 escape case,
// which means "every residual in this partition is zero".
func TestDecodeResidual_EscapeZeroWidth(t *testing.T) {
	const predictorOrder = 0
	const blockSize = 4

	var w testBitWriter
	w.writeBits(0, 2)
	w.writeBits(0, 4)
	w.writeBits(riceEscapeParam4, 4)
	w.writeBits(0, 5) // width 0

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, blockSize)
	if err := decodeResidual(br, blockSize, predictorOrder, out); err != nil {
		t.Fatalf("decodeResidual failed: %v", err)
	}
	for i, got := range out {
		if got != 0 {
			t.Errorf("sample %d: got %d, want 0", i, got)
		}
	}
}

// TestDecodeResidual_RejectsUnevenPartitioning asserts that a partition
// order which does not evenly divide the block size is rejected rather
// than silently truncated.
func TestDecodeResidual_RejectsUnevenPartitioning(t *testing.T) {
	var w testBitWriter
	w.writeBits(0, 2)
	w.writeBits(1, 4) // partition order 1 -> 2 partitions; blockSize 9 doesn't divide evenly

	br := NewBitReader(bytes.NewReader(w.bytesPadded()))
	out := make([]int32, 9)
	if err := decodeResidual(br, 9, 0, out); err == nil {
		t.Fatal("expected an error for uneven partitioning, got nil")
	}
}

// TestDecodeResidual_RejectsOversizedPredictorOrder asserts that a
// predictor order exceeding the block size is rejected up front.
func TestDecodeResidual_RejectsOversizedPredictorOrder(t *testing.T) {
	out := make([]int32, 4)
	br := NewBitReader(bytes.NewReader(nil))
	if err := decodeResidual(br, 4, 5, out); err == nil {
		t.Fatal("expected an error for predictor order exceeding block size, got nil")
	}
}
