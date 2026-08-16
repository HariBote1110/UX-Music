// This file implements sample-accurate seeking: a SEEKTABLE fast path when
// the stream carries one (RFC 9639 §8.5), and a CRC-8-validated binary
// search over the frame byte range otherwise.
package flac

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// seekPoint is one parsed SEEKTABLE entry: sampleNumber is the first sample
// of the target frame, byteOffset is measured from Stream.AudioStart.
type seekPoint struct {
	sampleNumber uint64
	byteOffset   uint64
}

const (
	seekPointSize        = 18 // 8 + 8 + 2 bytes, RFC 9639 §8.5
	seekPointPlaceholder = 0xFFFFFFFFFFFFFFFF
)

// parseSeekTable decodes a SEEKTABLE block's raw payload, skipping
// placeholder points (first-sample-number 0xFFFFFFFFFFFFFFFF).
func parseSeekTable(raw []byte) []seekPoint {
	var points []seekPoint
	for off := 0; off+seekPointSize <= len(raw); off += seekPointSize {
		sampleNum := binary.BigEndian.Uint64(raw[off : off+8])
		if sampleNum == seekPointPlaceholder {
			continue
		}
		byteOffset := binary.BigEndian.Uint64(raw[off+8 : off+16])
		points = append(points, seekPoint{sampleNumber: sampleNum, byteOffset: byteOffset})
	}
	return points
}

// bestSeekTableOffset returns the absolute byte offset (AudioStart plus the
// seek point's stored offset) of the seek point with the greatest sample
// number not exceeding target, or audioStart itself if no point qualifies.
func bestSeekTableOffset(points []seekPoint, target uint64, audioStart int64) int64 {
	best := audioStart
	var bestSample uint64
	found := false
	for _, p := range points {
		if p.sampleNumber > target {
			continue
		}
		if !found || p.sampleNumber >= bestSample {
			bestSample = p.sampleNumber
			best = audioStart + int64(p.byteOffset)
			found = true
		}
	}
	return best
}

// frameStartSample resolves the sample-stream position of a frame's first
// sample from its (already CRC-8-validated) header: an explicit sample
// number for variable-block-size streams, or the frame number multiplied by
// the stream's fixed block size otherwise.
func frameStartSample(header *FrameHeader, info StreamInfo) int64 {
	if header.VariableBlockSize {
		return header.Number
	}
	blockSize := info.MaxBlockSize
	if blockSize <= 0 {
		blockSize = header.BlockSize
	}
	return header.Number * int64(blockSize)
}

// SeekSample positions the decoder so the next call to ReadFrame returns a
// frame beginning exactly at sample: internally it decodes forward to the
// frame containing sample and, if sample falls mid-frame, trims the frame's
// head so no earlier sample is ever returned. Seeking to a negative sample,
// or beyond the stream's STREAMINFO total sample count, is an error.
func (d *Decoder) SeekSample(sample int64) error {
	d.pendingFrame = nil
	d.pendingSkip = 0

	if sample < 0 {
		return fmt.Errorf("flac: cannot seek to negative sample %d", sample)
	}
	if d.stream.Info.TotalSamples > 0 && sample > d.stream.Info.TotalSamples {
		return fmt.Errorf("flac: cannot seek to sample %d beyond stream total %d", sample, d.stream.Info.TotalSamples)
	}

	fileEnd, err := d.rs.Seek(0, io.SeekEnd)
	if err != nil {
		return fmt.Errorf("flac: failed to determine stream length for seek: %w", err)
	}

	var candidateOffset int64
	if points := parseSeekTable(d.stream.SeekTableRaw); len(points) > 0 {
		candidateOffset = bestSeekTableOffset(points, uint64(sample), d.stream.AudioStart)
	} else {
		candidateOffset, err = d.binarySearchFrameOffset(sample, fileEnd)
		if err != nil {
			return err
		}
	}

	if _, err := d.rs.Seek(candidateOffset, io.SeekStart); err != nil {
		return fmt.Errorf("flac: failed to seek to candidate frame offset: %w", err)
	}
	d.br = NewBitReader(d.rs)

	// Decode forward, one full frame at a time, until we reach the frame
	// that contains the target sample.
	for {
		atEOF, err := d.br.AtEOF()
		if err != nil {
			return err
		}
		if atEOF {
			// The target sample is not reachable (can happen for a stream
			// with an inaccurate/absent total sample count): leave the
			// decoder positioned so the next ReadFrame reports io.EOF,
			// consistent with a normal decode running off the end.
			return nil
		}

		header, err := decodeFrame(d.br, d.stream.Info, d.chBufs)
		if err != nil {
			return fmt.Errorf("flac: seek failed while decoding toward target frame: %w", err)
		}

		frameStart := frameStartSample(header, d.stream.Info)
		if frameStart+int64(header.BlockSize) > sample {
			skip := sample - frameStart
			if skip < 0 {
				skip = 0
			}

			d.frame.BlockSize = header.BlockSize
			d.frame.SampleRate = header.SampleRate
			d.frame.Channels = header.Channels
			d.frame.BitsPerSample = header.BitsPerSample
			for i := 0; i < header.Channels; i++ {
				d.frame.Samples[i] = d.chBufs[i][:header.BlockSize]
			}

			d.pendingFrame = &d.frame
			d.pendingSkip = int(skip)
			return nil
		}
	}
}

// binarySearchFrameOffset finds a byte offset to start decoding forward
// from, for streams without a SEEKTABLE: it narrows [d.stream.AudioStart,
// fileEnd) using frame header sample positions obtained via
// CRC-8-validated sync scanning (scanForFrame), converging on the frame
// with the greatest start sample not exceeding target.
func (d *Decoder) binarySearchFrameOffset(target, fileEnd int64) (int64, error) {
	lo, hi := d.stream.AudioStart, fileEnd
	best := d.stream.AudioStart

	// Bounded iteration count: each step at minimum halves [lo, hi), so a
	// generous constant safely covers any realistic file size.
	for iter := 0; iter < 64 && lo < hi; iter++ {
		mid := lo + (hi-lo)/2

		offset, sampleAt, err := d.scanForFrame(mid, fileEnd)
		if err != nil {
			// No valid frame header between mid and fileEnd: everything
			// from mid onward is out of range, narrow left.
			if mid <= lo {
				break
			}
			hi = mid
			continue
		}

		if sampleAt <= target {
			best = offset
			if offset >= hi-1 {
				break
			}
			lo = offset + 1
		} else {
			if mid <= lo {
				break
			}
			hi = mid
		}
	}

	return best, nil
}

// scanForFrame scans the byte range [from, limit) for the next position
// that parses as a valid frame header — sync code plus a validating CRC-8,
// both enforced by ParseFrameHeader — rejecting false sync matches. It
// returns the header's byte offset and its resolved start sample.
func (d *Decoder) scanForFrame(from, limit int64) (offset int64, sample int64, err error) {
	const chunkSize = 16384
	buf := make([]byte, chunkSize)

	for pos := from; pos < limit; {
		want := int64(len(buf))
		if pos+want > limit {
			want = limit - pos
		}
		if want <= 0 {
			break
		}
		if _, err := d.rs.Seek(pos, io.SeekStart); err != nil {
			return 0, 0, err
		}
		n, rerr := io.ReadFull(d.rs, buf[:want])
		if rerr != nil && rerr != io.ErrUnexpectedEOF && rerr != io.EOF {
			return 0, 0, rerr
		}

		for i := 0; i < n; i++ {
			if buf[i] != 0xFF {
				continue
			}
			candidate := pos + int64(i)
			if _, err := d.rs.Seek(candidate, io.SeekStart); err != nil {
				return 0, 0, err
			}
			br := NewBitReader(d.rs)
			header, herr := ParseFrameHeader(br, d.stream.Info)
			if herr != nil {
				continue
			}
			return candidate, frameStartSample(header, d.stream.Info), nil
		}

		if n < int(want) {
			break
		}
		pos += int64(n)
	}

	return 0, 0, errors.New("flac: no valid frame header found in scan range")
}
