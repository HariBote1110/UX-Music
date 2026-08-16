package flac

import (
	"bytes"
	"errors"
	"io"
	"testing"
)

func TestBitReader_ReadBitsUnsigned(t *testing.T) {
	// 0xB5 0x3C = 1011 0101  0011 1100
	data := []byte{0xB5, 0x3C}

	t.Run("single bits", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader(data))
		want := []uint64{1, 0, 1, 1, 0, 1, 0, 1}
		for i, w := range want {
			got, err := br.ReadBits(1)
			if err != nil {
				t.Fatalf("bit %d: unexpected error: %v", i, err)
			}
			if got != w {
				t.Fatalf("bit %d: got %d, want %d", i, got, w)
			}
		}
	})

	t.Run("four then twelve bits", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader(data))
		got, err := br.ReadBits(4)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 0xB {
			t.Fatalf("got %#x, want 0xB", got)
		}
		got, err = br.ReadBits(12)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 0x53C {
			t.Fatalf("got %#x, want 0x53C", got)
		}
	})

	t.Run("whole sixteen bits", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader(data))
		got, err := br.ReadBits(16)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 0xB53C {
			t.Fatalf("got %#x, want 0xB53C", got)
		}
	})

	t.Run("zero bits returns zero", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader(data))
		got, err := br.ReadBits(0)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 0 {
			t.Fatalf("got %#x, want 0", got)
		}
	})

	t.Run("more than 64 bits is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader(data))
		if _, err := br.ReadBits(65); err == nil {
			t.Fatalf("expected error for n>64, got nil")
		}
	})

	t.Run("64 bits across an 8 byte buffer", func(t *testing.T) {
		full := bytes.Repeat([]byte{0xAA}, 8)
		br := NewBitReader(bytes.NewReader(full))
		got, err := br.ReadBits(64)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		want := uint64(0xAAAAAAAAAAAAAAAA)
		if got != want {
			t.Fatalf("got %#x, want %#x", got, want)
		}
	})

	t.Run("truncated input yields ErrUnexpectedEOF", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0xFF}))
		if _, err := br.ReadBits(9); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("got err %v, want io.ErrUnexpectedEOF", err)
		}
	})

	t.Run("empty input yields ErrUnexpectedEOF", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader(nil))
		if _, err := br.ReadBits(1); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("got err %v, want io.ErrUnexpectedEOF", err)
		}
	})
}

func TestBitReader_ReadBitsSigned(t *testing.T) {
	cases := []struct {
		name string
		n    uint
		data []byte
		want int64
	}{
		{"4 bits positive", 4, []byte{0b0111_0000}, 7},
		{"4 bits negative", 4, []byte{0b1000_0000}, -8},
		{"4 bits negative -1", 4, []byte{0b1111_0000}, -1},
		{"8 bits negative", 8, []byte{0xFF}, -1},
		{"8 bits min", 8, []byte{0x80}, -128},
		{"1 bit zero", 1, []byte{0x00}, 0},
		{"1 bit one", 1, []byte{0x80}, -1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			br := NewBitReader(bytes.NewReader(tc.data))
			got, err := br.ReadBitsSigned(tc.n)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got %d, want %d", got, tc.want)
			}
		})
	}

	t.Run("64 bits sign extension", func(t *testing.T) {
		data := bytes.Repeat([]byte{0xFF}, 8)
		br := NewBitReader(bytes.NewReader(data))
		got, err := br.ReadBitsSigned(64)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != -1 {
			t.Fatalf("got %d, want -1", got)
		}
	})

	t.Run("zero n is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0x00}))
		if _, err := br.ReadBitsSigned(0); err == nil {
			t.Fatalf("expected error for n=0, got nil")
		}
	})
}

func TestBitReader_ReadUnary(t *testing.T) {
	t.Run("zero run then one", func(t *testing.T) {
		// 0000 0001 -> 7 zero bits then a one.
		br := NewBitReader(bytes.NewReader([]byte{0x01}))
		got, err := br.ReadUnary()
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 7 {
			t.Fatalf("got %d, want 7", got)
		}
	})

	t.Run("immediate one is zero run", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0xFF}))
		got, err := br.ReadUnary()
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 0 {
			t.Fatalf("got %d, want 0", got)
		}
	})

	t.Run("run spans byte boundary", func(t *testing.T) {
		// 0x00, 0x00, 0x01 -> 23 leading zero bits then a one bit.
		br := NewBitReader(bytes.NewReader([]byte{0x00, 0x00, 0x01}))
		got, err := br.ReadUnary()
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != 23 {
			t.Fatalf("got %d, want 23", got)
		}
	})

	t.Run("consecutive unary reads", func(t *testing.T) {
		// 1010 0100 -> runs of 0,1,2 then remaining bits 00 unterminated.
		br := NewBitReader(bytes.NewReader([]byte{0b1010_0100}))
		want := []uint32{0, 1, 2}
		for i, w := range want {
			got, err := br.ReadUnary()
			if err != nil {
				t.Fatalf("read %d: unexpected error: %v", i, err)
			}
			if got != w {
				t.Fatalf("read %d: got %d, want %d", i, got, w)
			}
		}
	})

	t.Run("all zero bits until EOF is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0x00, 0x00}))
		if _, err := br.ReadUnary(); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("got err %v, want io.ErrUnexpectedEOF", err)
		}
	})
}

func TestBitReader_Alignment(t *testing.T) {
	data := []byte{0xFF, 0xAB, 0xCD}
	br := NewBitReader(bytes.NewReader(data))

	if !br.Aligned() {
		t.Fatalf("expected fresh reader to be aligned")
	}

	if _, err := br.ReadBits(3); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if br.Aligned() {
		t.Fatalf("expected reader to be unaligned after reading 3 bits")
	}

	br.Align()
	if !br.Aligned() {
		t.Fatalf("expected reader to be aligned after Align()")
	}

	got, err := br.ReadBits(8)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 0xAB {
		t.Fatalf("got %#x, want 0xAB", got)
	}

	// Align while already aligned must be a no-op.
	br.Align()
	got, err = br.ReadBits(8)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 0xCD {
		t.Fatalf("got %#x, want 0xCD", got)
	}
}

func TestBitReader_ReadRawBytes(t *testing.T) {
	t.Run("aligned read succeeds", func(t *testing.T) {
		data := []byte{0x01, 0x02, 0x03, 0x04}
		br := NewBitReader(bytes.NewReader(data))
		got, err := br.ReadRawBytes(4)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !bytes.Equal(got, data) {
			t.Fatalf("got %v, want %v", got, data)
		}
	})

	t.Run("zero length read succeeds", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0x01}))
		got, err := br.ReadRawBytes(0)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(got) != 0 {
			t.Fatalf("got len %d, want 0", len(got))
		}
	})

	t.Run("unaligned read is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0xFF, 0x01}))
		if _, err := br.ReadBits(1); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if _, err := br.ReadRawBytes(1); err == nil {
			t.Fatalf("expected error for unaligned raw byte read")
		}
	})

	t.Run("truncated read yields ErrUnexpectedEOF", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0x01, 0x02}))
		if _, err := br.ReadRawBytes(3); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("got err %v, want io.ErrUnexpectedEOF", err)
		}
	})

	t.Run("negative length is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0x01}))
		if _, err := br.ReadRawBytes(-1); err == nil {
			t.Fatalf("expected error for negative length")
		}
	})
}

func TestBitReader_ReadUTF8Uint64(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want uint64
	}{
		{"1 byte", []byte{0x41}, 0x41},
		{"1 byte zero", []byte{0x00}, 0},
		{"2 bytes", []byte{0xC8, 0x80}, 0x200}, // 110_01000 10_000000 -> 01000 000000 = 0x200
		{"3 bytes", []byte{0xE0, 0x80, 0x80}, 0},
		{"7 bytes max width", []byte{0xFE, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF}, 0xFFFFFFFFF},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			br := NewBitReader(bytes.NewReader(tc.data))
			got, err := br.ReadUTF8Uint64()
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got %#x, want %#x", got, tc.want)
			}
		})
	}

	t.Run("continuation-only lead byte is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0x80}))
		if _, err := br.ReadUTF8Uint64(); err == nil {
			t.Fatalf("expected error for continuation-only lead byte")
		}
	})

	t.Run("all-ones lead byte is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0xFF, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80}))
		if _, err := br.ReadUTF8Uint64(); err == nil {
			t.Fatalf("expected error for 0xFF lead byte")
		}
	})

	t.Run("invalid continuation byte is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0xC8, 0x00}))
		if _, err := br.ReadUTF8Uint64(); err == nil {
			t.Fatalf("expected error for invalid continuation byte")
		}
	})

	t.Run("truncated multi-byte sequence is an error", func(t *testing.T) {
		br := NewBitReader(bytes.NewReader([]byte{0xE0, 0x80}))
		if _, err := br.ReadUTF8Uint64(); !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("got err %v, want io.ErrUnexpectedEOF", err)
		}
	})
}

func TestBitReader_BitsRead(t *testing.T) {
	data := []byte{0xFF, 0xFF, 0xFF}
	br := NewBitReader(bytes.NewReader(data))
	if got := br.BitsRead(); got != 0 {
		t.Fatalf("got %d, want 0", got)
	}
	if _, err := br.ReadBits(5); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := br.BitsRead(); got != 5 {
		t.Fatalf("got %d, want 5", got)
	}
	if _, err := br.ReadUnary(); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := br.BitsRead(); got != 6 {
		t.Fatalf("got %d, want 6", got)
	}
	br.Align()
	if got := br.BitsRead(); got != 8 {
		t.Fatalf("got %d, want 8", got)
	}
}
