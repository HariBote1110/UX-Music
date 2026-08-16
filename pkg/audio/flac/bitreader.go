// Package flac implements a hand-written FLAC decoder, built to replace the
// reflect/unsafe-laden path through github.com/mewkiz/flac used elsewhere in
// this repository. This file provides the MSB-first bit reader that every
// later stage (stream/frame header parsing, and eventually subframe and
// residual decoding) is built on.
package flac

import (
	"errors"
	"fmt"
	"io"
)

// bitReaderBufSize is the size of the internal read-ahead buffer. It is
// large enough to amortise the cost of the underlying io.Reader across many
// bit reads without growing unreasonably large.
const bitReaderBufSize = 4096

// BitReader reads individual bits, MSB first, from an underlying io.Reader.
// It never panics: every method that can fail returns an error, and all
// buffer indexing is bounds-guarded.
type BitReader struct {
	r   io.Reader
	buf [bitReaderBufSize]byte

	bufLen int  // number of valid bytes currently in buf
	bufPos int  // index of the next byte in buf to consume
	bitOff uint // 0..7: next bit to consume within buf[bufPos], MSB first

	totalBits uint64 // total bits successfully consumed so far

	capturing bool   // whether consumed bytes are being recorded, see StartCapture
	capture   []byte // bytes consumed since the last StartCapture, in order
}

// NewBitReader creates a BitReader that reads from r.
func NewBitReader(r io.Reader) *BitReader {
	return &BitReader{r: r}
}

// fill refills the internal buffer from the underlying reader. It returns an
// error only when no further bytes are available.
func (b *BitReader) fill() error {
	n, err := b.r.Read(b.buf[:])
	if n > 0 {
		b.bufLen = n
		b.bufPos = 0
		b.bitOff = 0
		return nil
	}
	if err == nil {
		// A zero-byte, nil-error read is a valid (if unusual) io.Reader
		// response; treat it as "try again" rather than EOF.
		return b.fill()
	}
	return err
}

// readBit returns the next single bit (0 or 1). Any failure to obtain a bit,
// including a clean io.EOF from the underlying reader, is reported as
// io.ErrUnexpectedEOF: callers are always mid-way through reading a
// specific-width field, so a bare EOF here always means truncated input.
func (b *BitReader) readBit() (uint64, error) {
	if b.bufPos >= b.bufLen {
		if err := b.fill(); err != nil {
			return 0, io.ErrUnexpectedEOF
		}
	}
	value := b.buf[b.bufPos]
	bit := (value >> (7 - b.bitOff)) & 1
	b.bitOff++
	b.totalBits++
	if b.bitOff == 8 {
		if b.capturing {
			b.capture = append(b.capture, value)
		}
		b.bitOff = 0
		b.bufPos++
	}
	return uint64(bit), nil
}

// ReadBits reads n bits (0 <= n <= 64) and returns them as an unsigned
// value, MSB first.
func (b *BitReader) ReadBits(n uint) (uint64, error) {
	if n > 64 {
		return 0, fmt.Errorf("flac: cannot read %d bits at once (maximum is 64)", n)
	}
	var v uint64
	for i := uint(0); i < n; i++ {
		bit, err := b.readBit()
		if err != nil {
			return 0, err
		}
		v = (v << 1) | bit
	}
	return v, nil
}

// ReadBitsSigned reads n bits (1 <= n <= 64) as a two's-complement signed
// value, sign-extended to int64.
func (b *BitReader) ReadBitsSigned(n uint) (int64, error) {
	if n == 0 || n > 64 {
		return 0, fmt.Errorf("flac: cannot read %d signed bits (must be 1..64)", n)
	}
	u, err := b.ReadBits(n)
	if err != nil {
		return 0, err
	}
	if n == 64 {
		return int64(u), nil
	}
	signBit := uint64(1) << (n - 1)
	if u&signBit != 0 {
		u |= ^uint64(0) << n
	}
	return int64(u), nil
}

// ReadUnary reads a Rice-coded unary value: the number of consecutive zero
// bits before the next one bit. The terminating one bit is consumed but not
// counted. This is the hot path for Rice-coded residuals in later
// increments.
func (b *BitReader) ReadUnary() (uint32, error) {
	var count uint32
	for {
		bit, err := b.readBit()
		if err != nil {
			return 0, err
		}
		if bit == 1 {
			return count, nil
		}
		count++
	}
}

// Aligned reports whether the reader is currently positioned on a byte
// boundary.
func (b *BitReader) Aligned() bool {
	return b.bitOff == 0
}

// Align advances the reader to the next byte boundary, discarding any
// partially-consumed bits. It is a no-op if the reader is already aligned.
func (b *BitReader) Align() {
	if b.bitOff == 0 {
		return
	}
	if b.capturing {
		b.capture = append(b.capture, b.buf[b.bufPos])
	}
	b.totalBits += uint64(8 - b.bitOff)
	b.bitOff = 0
	b.bufPos++
}

// ReadRawBytes reads n raw bytes. The reader must be byte-aligned; call
// Align first if necessary. n must be non-negative.
func (b *BitReader) ReadRawBytes(n int) ([]byte, error) {
	if n < 0 {
		return nil, fmt.Errorf("flac: cannot read a negative number of bytes (%d)", n)
	}
	if !b.Aligned() {
		return nil, errors.New("flac: ReadRawBytes called at a non-byte-aligned position")
	}
	out := make([]byte, n)
	for i := 0; i < n; i++ {
		if b.bufPos >= b.bufLen {
			if err := b.fill(); err != nil {
				return nil, io.ErrUnexpectedEOF
			}
		}
		out[i] = b.buf[b.bufPos]
		if b.capturing {
			b.capture = append(b.capture, b.buf[b.bufPos])
		}
		b.bufPos++
		b.totalBits += 8
	}
	return out, nil
}

// StartCapture begins recording every byte the reader fully consumes (via
// ReadBits, ReadBitsSigned, ReadUnary, ReadRawBytes or Align) from this
// point onward, discarding any bytes captured by a previous, unterminated
// capture. It is used to reconstruct the exact raw bytes of a frame for
// CRC-16 verification, since the reader's internal buffer may read ahead
// past the logical end of the current frame.
func (b *BitReader) StartCapture() {
	b.capturing = true
	b.capture = b.capture[:0]
}

// StopCapture ends recording and returns the bytes captured since the last
// StartCapture. The returned slice is only valid until the next call to
// StartCapture, which reuses its backing array.
func (b *BitReader) StopCapture() []byte {
	b.capturing = false
	return b.capture
}

// ReadUTF8Uint64 reads a FLAC/UTF-8-style extended number: an encoding of up
// to 36 bits across 1 to 7 bytes, used by frame headers to encode the frame
// or sample number. The reader must be byte-aligned, which frame headers
// guarantee by construction.
func (b *BitReader) ReadUTF8Uint64() (uint64, error) {
	first, err := b.ReadBits(8)
	if err != nil {
		return 0, err
	}
	b0 := byte(first)
	if b0&0x80 == 0 {
		return uint64(b0), nil
	}

	// Count the leading one bits to determine the total byte count.
	n := 0
	mask := byte(0x80)
	for mask != 0 && b0&mask != 0 {
		n++
		mask >>= 1
	}
	if n < 2 || n > 7 {
		return 0, fmt.Errorf("flac: invalid UTF-8 coded number lead byte 0x%02x", b0)
	}

	value := uint64(b0 & (0xFF >> uint(n+1)))
	for i := 1; i < n; i++ {
		cb, err := b.ReadBits(8)
		if err != nil {
			return 0, err
		}
		c := byte(cb)
		if c&0xC0 != 0x80 {
			return 0, fmt.Errorf("flac: invalid UTF-8 coded number continuation byte 0x%02x", c)
		}
		value = (value << 6) | uint64(c&0x3F)
	}
	return value, nil
}

// BitsRead returns the total number of bits successfully consumed so far.
func (b *BitReader) BitsRead() uint64 {
	return b.totalBits
}

// AtEOF reports whether the reader has definitively reached the end of the
// underlying stream: no bytes remain buffered internally, and a further
// attempt to fill the buffer from the underlying io.Reader yields a clean
// io.EOF. It is intended to be called only at a byte-aligned position,
// between logical units (e.g. between frames), and never consumes a bit.
//
// A false return with a non-nil error means refilling the buffer failed
// with something other than a clean end-of-stream (a genuine I/O error),
// which callers should treat as a hard failure rather than "no more data".
func (b *BitReader) AtEOF() (bool, error) {
	if b.bufPos < b.bufLen {
		return false, nil
	}
	if err := b.fill(); err != nil {
		if errors.Is(err, io.EOF) {
			return true, nil
		}
		return false, err
	}
	return false, nil
}
