package flac

// testBitWriter is a minimal MSB-first bit writer used only by tests to
// hand-construct bitstreams that exercise decodeResidual / decodeSubframe
// against known-good encodings, independent of the acceptance test's
// reliance on the external `flac` CLI.
type testBitWriter struct {
	bytes  []byte
	cur    byte
	bitPos uint // number of bits already placed into cur, MSB first
}

func (w *testBitWriter) writeBits(value uint64, n uint) {
	for i := int(n) - 1; i >= 0; i-- {
		bit := byte((value >> uint(i)) & 1)
		w.cur = (w.cur << 1) | bit
		w.bitPos++
		if w.bitPos == 8 {
			w.bytes = append(w.bytes, w.cur)
			w.cur = 0
			w.bitPos = 0
		}
	}
}

// writeSigned writes n bits of a two's-complement signed value.
func (w *testBitWriter) writeSigned(value int64, n uint) {
	mask := uint64(1)<<n - 1
	w.writeBits(uint64(value)&mask, n)
}

// writeUnary writes q zero bits followed by a terminating one bit.
func (w *testBitWriter) writeUnary(q uint32) {
	for i := uint32(0); i < q; i++ {
		w.writeBits(0, 1)
	}
	w.writeBits(1, 1)
}

// writeRice writes a signed value Rice-coded with parameter k.
func (w *testBitWriter) writeRice(value int32, k uint) {
	v := int64(value)
	var folded uint64
	if v >= 0 {
		folded = uint64(v) << 1
	} else {
		folded = (uint64(-v) << 1) - 1
	}
	q := uint32(folded >> k)
	w.writeUnary(q)
	if k > 0 {
		w.writeBits(folded&(uint64(1)<<k-1), k)
	}
}

// bytesPadded flushes any partial trailing byte (zero-padded) and returns
// the accumulated bytes.
func (w *testBitWriter) bytesPadded() []byte {
	if w.bitPos == 0 {
		return w.bytes
	}
	pad := 8 - w.bitPos
	w.cur <<= pad
	return append(w.bytes, w.cur)
}
