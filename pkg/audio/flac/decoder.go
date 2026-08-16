// This file provides the public streaming decoder API: NewDecoder,
// Decoder.Info, Decoder.ReadFrame and Decoder.Close.
package flac

import (
	"errors"
	"fmt"
	"io"
)

// Frame is one decoded FLAC frame: per-channel samples, already
// decorrelated and with wasted bits re-applied, alongside the frame's
// resolved parameters. The Samples slices are reused across calls to
// Decoder.ReadFrame and are only valid until the next call.
type Frame struct {
	BlockSize     int
	SampleRate    int
	Channels      int
	BitsPerSample int
	Samples       [][]int32
}

// defaultMaxBlockSize is used to size decode buffers when a stream's
// STREAMINFO reports a max block size of 0 (legal but unusual: it means the
// encoder did not know the value up front). 65535 is the largest block size
// any FLAC frame header can encode.
const defaultMaxBlockSize = 65535

// Decoder is a streaming FLAC decoder: it reads and decodes one frame at a
// time from an underlying stream, reusing its internal buffers across
// calls.
type Decoder struct {
	stream *Stream
	rs     io.ReadSeeker
	br     *BitReader

	chBufs [][]int32 // one reusable buffer per channel, sized to the stream's max block size
	frame  Frame     // reused across ReadFrame calls; Samples reslices chBufs

	// pendingFrame, when non-nil, is a frame already decoded by SeekSample
	// (trimmed to start at the requested target sample) that the next call
	// to ReadFrame should return without decoding anything further.
	pendingFrame *Frame
	pendingSkip  int // samples to trim from the head of pendingFrame
}

// NewDecoder parses the FLAC stream header from rs (ID3v2 skip, "fLaC"
// signature, metadata chain) and positions the decoder at the start of the
// first audio frame, ready for ReadFrame.
func NewDecoder(rs io.ReadSeeker) (*Decoder, error) {
	if rs == nil {
		return nil, errors.New("flac: NewDecoder requires a non-nil io.ReadSeeker")
	}

	stream, err := ParseStream(rs)
	if err != nil {
		return nil, err
	}

	if _, err := rs.Seek(stream.AudioStart, io.SeekStart); err != nil {
		return nil, fmt.Errorf("flac: failed to seek to first audio frame: %w", err)
	}

	maxBlock := stream.Info.MaxBlockSize
	if maxBlock <= 0 {
		maxBlock = defaultMaxBlockSize
	}

	channels := stream.Info.Channels
	chBufs := make([][]int32, channels)
	for i := range chBufs {
		chBufs[i] = make([]int32, maxBlock)
	}

	d := &Decoder{
		stream: stream,
		rs:     rs,
		br:     NewBitReader(rs),
		chBufs: chBufs,
	}
	d.frame.Samples = make([][]int32, channels)
	return d, nil
}

// Info returns the stream's STREAMINFO metadata.
func (d *Decoder) Info() StreamInfo {
	return d.stream.Info
}

// ReadFrame decodes and returns the next audio frame. It returns io.EOF
// (and a nil *Frame) once the stream is exhausted cleanly, i.e. no further
// bytes remain at a frame boundary. Any other error means the stream ended,
// or was corrupt, in the middle of a frame. The returned *Frame is only
// valid until the next call to ReadFrame or Close.
func (d *Decoder) ReadFrame() (*Frame, error) {
	if d.pendingFrame != nil {
		frame := d.pendingFrame
		skip := d.pendingSkip
		d.pendingFrame = nil
		d.pendingSkip = 0
		if skip > 0 {
			frame.BlockSize -= skip
			for i := range frame.Samples {
				frame.Samples[i] = frame.Samples[i][skip:]
			}
		}
		return frame, nil
	}

	atEOF, err := d.br.AtEOF()
	if err != nil {
		return nil, err
	}
	if atEOF {
		return nil, io.EOF
	}

	header, err := decodeFrame(d.br, d.stream.Info, d.chBufs)
	if err != nil {
		return nil, err
	}

	d.frame.BlockSize = header.BlockSize
	d.frame.SampleRate = header.SampleRate
	d.frame.Channels = header.Channels
	d.frame.BitsPerSample = header.BitsPerSample
	for i := 0; i < header.Channels; i++ {
		d.frame.Samples[i] = d.chBufs[i][:header.BlockSize]
	}

	return &d.frame, nil
}

// Close releases resources held by the decoder. If the underlying
// io.ReadSeeker also implements io.Closer, it is closed too.
func (d *Decoder) Close() error {
	if c, ok := d.rs.(io.Closer); ok {
		return c.Close()
	}
	return nil
}
