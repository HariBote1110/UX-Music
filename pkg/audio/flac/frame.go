package flac

import "fmt"

// ChannelAssignment identifies how a frame's channels are decorrelated.
type ChannelAssignment int

const (
	// ChannelIndependent means every channel is stored independently.
	ChannelIndependent ChannelAssignment = iota
	// ChannelLeftSide means channel 0 is left, channel 1 is (left-right).
	ChannelLeftSide
	// ChannelRightSide means channel 0 is (left-right), channel 1 is right.
	ChannelRightSide
	// ChannelMidSide means channel 0 is mid, channel 1 is (left-right).
	ChannelMidSide
)

// FrameHeader is a fully-resolved FLAC frame header: coded values (block
// size code, sample rate code, etc.) have already been looked up against
// their tables and, where the code means "use STREAMINFO", resolved
// against the StreamInfo passed to ParseFrameHeader.
type FrameHeader struct {
	BlockSize             int // in samples
	SampleRate            int // in Hz
	Channels              int // channel count implied by ChannelAssignmentType
	ChannelAssignmentType ChannelAssignment
	BitsPerSample         int

	// VariableBlockSize is true when the stream uses variable block sizes,
	// in which case Number is the sample number of the first sample in the
	// frame. When false (fixed block size), Number is the frame number.
	VariableBlockSize bool
	Number            int64
}

// crc8Table is the lookup table for the CRC-8 (polynomial x^8+x^2+x+1,
// 0x07, no reflection, initial value 0) used to guard FLAC frame headers.
var crc8Table = buildCRC8Table()

func buildCRC8Table() [256]byte {
	var table [256]byte
	for i := 0; i < 256; i++ {
		crc := byte(i)
		for bit := 0; bit < 8; bit++ {
			if crc&0x80 != 0 {
				crc = (crc << 1) ^ 0x07
			} else {
				crc <<= 1
			}
		}
		table[i] = crc
	}
	return table
}

func crc8(data []byte) byte {
	var crc byte
	for _, b := range data {
		crc = crc8Table[crc^b]
	}
	return crc
}

// blockSizeFromCode resolves the 4-bit block size code, reading a trailing
// 8- or 16-bit value from br (and appending its raw bytes to raw) when the
// code requests it.
func blockSizeFromCode(br *BitReader, code byte, raw *[]byte) (int, error) {
	switch {
	case code == 0x0:
		return 0, fmt.Errorf("flac: reserved frame block size code 0x0")
	case code == 0x1:
		return 192, nil
	case code >= 0x2 && code <= 0x5:
		return 576 << (code - 0x2), nil
	case code == 0x6:
		ext, err := br.ReadRawBytes(1)
		if err != nil {
			return 0, err
		}
		*raw = append(*raw, ext...)
		return int(ext[0]) + 1, nil
	case code == 0x7:
		ext, err := br.ReadRawBytes(2)
		if err != nil {
			return 0, err
		}
		*raw = append(*raw, ext...)
		return (int(ext[0])<<8 | int(ext[1])) + 1, nil
	case code >= 0x8:
		return 256 << (code - 0x8), nil
	default:
		return 0, fmt.Errorf("flac: unrecognised frame block size code %#x", code)
	}
}

// sampleRateFromCode resolves the 4-bit sample rate code, reading a
// trailing 8- or 16-bit value from br when the code requests it, and
// falling back to streamRate (from STREAMINFO) for code 0x0.
func sampleRateFromCode(br *BitReader, code byte, streamRate int, raw *[]byte) (int, error) {
	switch code {
	case 0x0:
		return streamRate, nil
	case 0x1:
		return 88200, nil
	case 0x2:
		return 176400, nil
	case 0x3:
		return 192000, nil
	case 0x4:
		return 8000, nil
	case 0x5:
		return 16000, nil
	case 0x6:
		return 22050, nil
	case 0x7:
		return 24000, nil
	case 0x8:
		return 32000, nil
	case 0x9:
		return 44100, nil
	case 0xA:
		return 48000, nil
	case 0xB:
		return 96000, nil
	case 0xC:
		ext, err := br.ReadRawBytes(1)
		if err != nil {
			return 0, err
		}
		*raw = append(*raw, ext...)
		return int(ext[0]) * 1000, nil
	case 0xD:
		ext, err := br.ReadRawBytes(2)
		if err != nil {
			return 0, err
		}
		*raw = append(*raw, ext...)
		return int(ext[0])<<8 | int(ext[1]), nil
	case 0xE:
		ext, err := br.ReadRawBytes(2)
		if err != nil {
			return 0, err
		}
		*raw = append(*raw, ext...)
		return (int(ext[0])<<8 | int(ext[1])) * 10, nil
	case 0xF:
		return 0, fmt.Errorf("flac: reserved frame sample rate code 0xF (would risk fooling sync detection)")
	default:
		return 0, fmt.Errorf("flac: unrecognised frame sample rate code %#x", code)
	}
}

// channelsFromCode resolves the 4-bit channel assignment code into a
// channel count and its ChannelAssignment.
func channelsFromCode(code byte) (channels int, assignment ChannelAssignment, err error) {
	switch {
	case code <= 0x7:
		return int(code) + 1, ChannelIndependent, nil
	case code == 0x8:
		return 2, ChannelLeftSide, nil
	case code == 0x9:
		return 2, ChannelRightSide, nil
	case code == 0xA:
		return 2, ChannelMidSide, nil
	default:
		return 0, 0, fmt.Errorf("flac: reserved frame channel assignment code %#x", code)
	}
}

// bitsPerSampleFromCode resolves the 3-bit sample size code, falling back
// to streamBits (from STREAMINFO) for code 0x0.
func bitsPerSampleFromCode(code byte, streamBits int) (int, error) {
	switch code {
	case 0x0:
		return streamBits, nil
	case 0x1:
		return 8, nil
	case 0x2:
		return 12, nil
	case 0x3:
		return 0, fmt.Errorf("flac: reserved frame sample size code 0x3")
	case 0x4:
		return 16, nil
	case 0x5:
		return 20, nil
	case 0x6:
		return 24, nil
	case 0x7:
		return 32, nil
	default:
		return 0, fmt.Errorf("flac: unrecognised frame sample size code %#x", code)
	}
}

// readCodedNumber reads a FLAC/UTF-8-style extended number (1 to 7 bytes,
// up to 36 bits), returning both the decoded value and the raw bytes
// consumed, since the raw bytes are needed for the frame header's CRC-8.
// The reader must be byte-aligned, which it always is at this point in a
// frame header.
func readCodedNumber(br *BitReader) (value uint64, raw []byte, err error) {
	first, err := br.ReadRawBytes(1)
	if err != nil {
		return 0, nil, err
	}
	raw = append(raw, first[0])
	b0 := first[0]
	if b0&0x80 == 0 {
		return uint64(b0), raw, nil
	}

	n := 0
	mask := byte(0x80)
	for mask != 0 && b0&mask != 0 {
		n++
		mask >>= 1
	}
	if n < 2 || n > 7 {
		return 0, raw, fmt.Errorf("flac: invalid coded number lead byte 0x%02x", b0)
	}

	value = uint64(b0 & (0xFF >> uint(n+1)))
	for i := 1; i < n; i++ {
		cont, err := br.ReadRawBytes(1)
		if err != nil {
			return 0, raw, err
		}
		raw = append(raw, cont[0])
		c := cont[0]
		if c&0xC0 != 0x80 {
			return 0, raw, fmt.Errorf("flac: invalid coded number continuation byte 0x%02x", c)
		}
		value = (value << 6) | uint64(c&0x3F)
	}
	return value, raw, nil
}

// ParseFrameHeader parses a single FLAC frame header from br, verifying its
// CRC-8 and resolving all coded fields into concrete values. Codes that
// mean "use STREAMINFO" are resolved against info. br must be positioned at
// a byte boundary at the start of a frame (ParseStream's Stream.AudioStart
// gives that position for the first frame).
func ParseFrameHeader(br *BitReader, info StreamInfo) (*FrameHeader, error) {
	fixed, err := br.ReadRawBytes(4)
	if err != nil {
		return nil, err
	}
	raw := append([]byte(nil), fixed...)

	b0, b1, b2, b3 := fixed[0], fixed[1], fixed[2], fixed[3]

	sync14 := uint16(b0)<<6 | uint16(b1>>2)
	if sync14 != 0x3FFE {
		return nil, fmt.Errorf("flac: invalid frame sync code %#04x", sync14)
	}
	if (b1>>1)&1 != 0 {
		return nil, fmt.Errorf("flac: frame header reserved bit is set (expected 0)")
	}
	variableBlockSize := b1&1 != 0
	blockSizeCode := (b2 >> 4) & 0xF
	sampleRateCode := b2 & 0xF
	channelCode := (b3 >> 4) & 0xF
	sampleSizeCode := (b3 >> 1) & 0x7
	if b3&1 != 0 {
		return nil, fmt.Errorf("flac: frame header trailing reserved bit is set (expected 0)")
	}

	number, numberRaw, err := readCodedNumber(br)
	if err != nil {
		return nil, err
	}
	raw = append(raw, numberRaw...)

	blockSize, err := blockSizeFromCode(br, blockSizeCode, &raw)
	if err != nil {
		return nil, err
	}

	sampleRate, err := sampleRateFromCode(br, sampleRateCode, info.SampleRate, &raw)
	if err != nil {
		return nil, err
	}

	channels, assignment, err := channelsFromCode(channelCode)
	if err != nil {
		return nil, err
	}

	bitsPerSample, err := bitsPerSampleFromCode(sampleSizeCode, info.BitsPerSample)
	if err != nil {
		return nil, err
	}

	crcByte, err := br.ReadRawBytes(1)
	if err != nil {
		return nil, err
	}
	wantCRC := crcByte[0]
	gotCRC := crc8(raw)
	if gotCRC != wantCRC {
		return nil, fmt.Errorf("flac: frame header CRC-8 mismatch (computed %#02x, header says %#02x)", gotCRC, wantCRC)
	}

	return &FrameHeader{
		BlockSize:             blockSize,
		SampleRate:            sampleRate,
		Channels:              channels,
		ChannelAssignmentType: assignment,
		BitsPerSample:         bitsPerSample,
		VariableBlockSize:     variableBlockSize,
		Number:                int64(number),
	}, nil
}
