package audio

import "testing"

// floatRingBuffer はプロセスタップ捕捉用のロックフリー SPSC リングバッファ。
// 書き手（Core Audio のリアルタイムスレッド）は絶対にブロックしない前提で、
// 満杯時は書き込みを黙って破棄しつつ破棄数を記録する仕様を検証する。

func TestFloatRingBufferWriteThenRead(t *testing.T) {
	t.Parallel()
	ring := newFloatRingBuffer(8)

	written := ring.Write([]float32{1, 2, 3})
	if written != 3 {
		t.Fatalf("write: got %d, want 3", written)
	}
	if got := ring.Len(); got != 3 {
		t.Fatalf("len after write: got %d, want 3", got)
	}

	dst := make([]float32, 3)
	read := ring.Read(dst)
	if read != 3 {
		t.Fatalf("read: got %d, want 3", read)
	}
	for i, want := range []float32{1, 2, 3} {
		if dst[i] != want {
			t.Fatalf("dst[%d]: got %g, want %g", i, dst[i], want)
		}
	}
	if got := ring.Len(); got != 0 {
		t.Fatalf("len after read: got %d, want 0", got)
	}
}

func TestFloatRingBufferReadFromEmptyReturnsZero(t *testing.T) {
	t.Parallel()
	ring := newFloatRingBuffer(4)
	dst := make([]float32, 4)
	if read := ring.Read(dst); read != 0 {
		t.Fatalf("read from empty: got %d, want 0", read)
	}
}

func TestFloatRingBufferWrapAround(t *testing.T) {
	t.Parallel()
	ring := newFloatRingBuffer(4)

	if written := ring.Write([]float32{1, 2, 3}); written != 3 {
		t.Fatalf("first write: got %d, want 3", written)
	}
	dst := make([]float32, 2)
	if read := ring.Read(dst); read != 2 {
		t.Fatalf("first read: got %d, want 2", read)
	}

	// 空き 3（容量 4、残 1）。書き込みが末尾を跨いで先頭へ折り返す。
	if written := ring.Write([]float32{4, 5, 6}); written != 3 {
		t.Fatalf("wrap write: got %d, want 3", written)
	}

	out := make([]float32, 4)
	if read := ring.Read(out); read != 4 {
		t.Fatalf("wrap read: got %d, want 4", read)
	}
	for i, want := range []float32{3, 4, 5, 6} {
		if out[i] != want {
			t.Fatalf("out[%d]: got %g, want %g", i, out[i], want)
		}
	}
}

func TestFloatRingBufferOverflowDropsAndCounts(t *testing.T) {
	t.Parallel()
	ring := newFloatRingBuffer(4)

	if written := ring.Write([]float32{1, 2, 3, 4}); written != 4 {
		t.Fatalf("fill write: got %d, want 4", written)
	}
	// 満杯なので全滅するはず。
	if written := ring.Write([]float32{5, 6}); written != 0 {
		t.Fatalf("overflow write: got %d, want 0", written)
	}
	if dropped := ring.Dropped(); dropped != 2 {
		t.Fatalf("dropped: got %d, want 2", dropped)
	}

	// 部分的に空きがある場合は書ける分だけ書き、残りを破棄する。
	dst := make([]float32, 1)
	if read := ring.Read(dst); read != 1 {
		t.Fatalf("partial read: got %d, want 1", read)
	}
	if written := ring.Write([]float32{7, 8, 9}); written != 1 {
		t.Fatalf("partial overflow write: got %d, want 1", written)
	}
	if dropped := ring.Dropped(); dropped != 4 {
		t.Fatalf("dropped after partial: got %d, want 4", dropped)
	}
}

func TestFloatRingBufferReceivedCountsAllOfferedSamples(t *testing.T) {
	t.Parallel()
	ring := newFloatRingBuffer(2)

	ring.Write([]float32{1, 2})
	ring.Write([]float32{3}) // 破棄されるが「受信」には数える
	if received := ring.Received(); received != 3 {
		t.Fatalf("received: got %d, want 3", received)
	}
}

func TestFloatRingBufferPartialRead(t *testing.T) {
	t.Parallel()
	ring := newFloatRingBuffer(8)
	ring.Write([]float32{1, 2})

	dst := make([]float32, 4)
	if read := ring.Read(dst); read != 2 {
		t.Fatalf("partial read: got %d, want 2", read)
	}
	if dst[0] != 1 || dst[1] != 2 {
		t.Fatalf("partial read contents: got %v", dst[:2])
	}
}
