package flac

import (
	"bufio"
	"errors"
	"fmt"
	"io"
)

// StreamInfo holds the mandatory FLAC STREAMINFO metadata block, decoded
// from its fixed 34-byte layout.
type StreamInfo struct {
	MinBlockSize  int
	MaxBlockSize  int
	MinFrameSize  int
	MaxFrameSize  int
	SampleRate    int
	Channels      int
	BitsPerSample int
	TotalSamples  int64
	MD5           [16]byte
}

// Stream is the result of parsing a FLAC stream header: the mandatory
// STREAMINFO block, the raw (not yet parsed) SEEKTABLE payload if present,
// and the byte offset in the original input at which the first audio frame
// begins.
type Stream struct {
	Info StreamInfo

	// SeekTableRaw holds the untouched payload of a SEEKTABLE metadata
	// block (type 3), if the stream has one. It is nil otherwise. Parsing
	// the seek point entries themselves is deferred to a later increment.
	SeekTableRaw []byte

	// AudioStart is the byte offset, measured from the very start of the
	// reader passed to ParseStream (i.e. including any skipped ID3v2
	// header), at which the first FLAC audio frame begins.
	AudioStart int64
}

// Metadata block type codes, per the FLAC format specification.
const (
	metadataBlockTypeStreamInfo = 0
	metadataBlockTypeSeekTable  = 3
)

// ParseStream reads a FLAC stream header from r: an optional leading ID3v2
// tag, the "fLaC" signature, and the metadata block chain up to and
// including the block with the last-metadata-block flag set. It does not
// read any audio frame data.
func ParseStream(r io.Reader) (*Stream, error) {
	bufr := bufio.NewReader(r)

	id3Len, err := skipID3v2(bufr)
	if err != nil {
		return nil, err
	}

	br := NewBitReader(bufr)

	magic, err := br.ReadRawBytes(4)
	if err != nil {
		return nil, err
	}
	if string(magic) != "fLaC" {
		return nil, fmt.Errorf("flac: missing fLaC stream signature")
	}

	stream := &Stream{}
	haveStreamInfo := false
	first := true

	for {
		blockHeader, err := br.ReadRawBytes(1)
		if err != nil {
			return nil, err
		}
		last := blockHeader[0]&0x80 != 0
		blockType := blockHeader[0] & 0x7F

		lengthBytes, err := br.ReadRawBytes(3)
		if err != nil {
			return nil, err
		}
		length := int(lengthBytes[0])<<16 | int(lengthBytes[1])<<8 | int(lengthBytes[2])

		if first && blockType != metadataBlockTypeStreamInfo {
			return nil, fmt.Errorf("flac: first metadata block must be STREAMINFO, got type %d", blockType)
		}
		first = false

		switch blockType {
		case metadataBlockTypeStreamInfo:
			if haveStreamInfo {
				return nil, fmt.Errorf("flac: duplicate STREAMINFO block")
			}
			if length != 34 {
				return nil, fmt.Errorf("flac: STREAMINFO block has unexpected length %d (want 34)", length)
			}
			info, err := parseStreamInfo(br)
			if err != nil {
				return nil, err
			}
			stream.Info = info
			haveStreamInfo = true
		case metadataBlockTypeSeekTable:
			raw, err := br.ReadRawBytes(length)
			if err != nil {
				return nil, err
			}
			stream.SeekTableRaw = raw
		default:
			if _, err := br.ReadRawBytes(length); err != nil {
				return nil, err
			}
		}

		if last {
			break
		}
	}

	if !haveStreamInfo {
		return nil, fmt.Errorf("flac: stream is missing the mandatory STREAMINFO block")
	}

	stream.AudioStart = int64(id3Len) + int64(br.BitsRead()/8)
	return stream, nil
}

// parseStreamInfo decodes a STREAMINFO block body (34 bytes / 272 bits) at
// br's current, byte-aligned position.
func parseStreamInfo(br *BitReader) (StreamInfo, error) {
	var info StreamInfo

	minBlock, err := br.ReadBits(16)
	if err != nil {
		return StreamInfo{}, err
	}
	info.MinBlockSize = int(minBlock)

	maxBlock, err := br.ReadBits(16)
	if err != nil {
		return StreamInfo{}, err
	}
	info.MaxBlockSize = int(maxBlock)

	minFrame, err := br.ReadBits(24)
	if err != nil {
		return StreamInfo{}, err
	}
	info.MinFrameSize = int(minFrame)

	maxFrame, err := br.ReadBits(24)
	if err != nil {
		return StreamInfo{}, err
	}
	info.MaxFrameSize = int(maxFrame)

	sampleRate, err := br.ReadBits(20)
	if err != nil {
		return StreamInfo{}, err
	}
	info.SampleRate = int(sampleRate)

	channelsMinusOne, err := br.ReadBits(3)
	if err != nil {
		return StreamInfo{}, err
	}
	info.Channels = int(channelsMinusOne) + 1

	bitsMinusOne, err := br.ReadBits(5)
	if err != nil {
		return StreamInfo{}, err
	}
	info.BitsPerSample = int(bitsMinusOne) + 1

	totalSamples, err := br.ReadBits(36)
	if err != nil {
		return StreamInfo{}, err
	}
	info.TotalSamples = int64(totalSamples)

	md5Bytes, err := br.ReadRawBytes(16)
	if err != nil {
		return StreamInfo{}, err
	}
	copy(info.MD5[:], md5Bytes)

	if info.Channels < 1 || info.Channels > 8 {
		return StreamInfo{}, fmt.Errorf("flac: STREAMINFO reports invalid channel count %d", info.Channels)
	}
	if info.BitsPerSample < 4 || info.BitsPerSample > 32 {
		return StreamInfo{}, fmt.Errorf("flac: STREAMINFO reports invalid bits-per-sample %d", info.BitsPerSample)
	}
	if info.SampleRate == 0 {
		return StreamInfo{}, fmt.Errorf("flac: STREAMINFO reports a zero sample rate")
	}

	return info, nil
}

// skipID3v2 detects an ID3v2 header at the current position of bufr and, if
// present, discards it (header, tag body, and footer if flagged). It
// returns the total number of bytes skipped, which is zero when no ID3v2
// header is present.
func skipID3v2(bufr *bufio.Reader) (int, error) {
	prefix, err := bufr.Peek(3)
	if err != nil {
		if errors.Is(err, io.EOF) {
			// Fewer than 3 bytes total: definitely not an ID3v2 header, and
			// the subsequent fLaC signature check will report the real
			// problem with the remaining bytes (if any).
			return 0, nil
		}
		return 0, err
	}
	if string(prefix) != "ID3" {
		return 0, nil
	}

	header := make([]byte, 10)
	if _, err := io.ReadFull(bufr, header); err != nil {
		return 0, io.ErrUnexpectedEOF
	}

	// header[3] = major version, header[4] = revision (both ignored here).
	flags := header[5]
	footerPresent := flags&0x10 != 0

	size := int(header[6]&0x7F)<<21 | int(header[7]&0x7F)<<14 | int(header[8]&0x7F)<<7 | int(header[9]&0x7F)

	if _, err := io.CopyN(io.Discard, bufr, int64(size)); err != nil {
		return 0, io.ErrUnexpectedEOF
	}
	total := 10 + size

	if footerPresent {
		if _, err := io.CopyN(io.Discard, bufr, 10); err != nil {
			return 0, io.ErrUnexpectedEOF
		}
		total += 10
	}

	return total, nil
}
