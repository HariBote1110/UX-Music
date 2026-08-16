// This file implements whole-frame decoding: driving subframe decoding for
// every channel, undoing stereo decorrelation, and verifying the frame's
// trailing CRC-16.
package flac

import "fmt"

// crc16Table is the lookup table for the CRC-16 (polynomial
// x^16+x^15+x^2+1, 0x8005, no reflection, initial value 0) used to guard
// whole FLAC frames.
var crc16Table = buildCRC16Table()

func buildCRC16Table() [256]uint16 {
	var table [256]uint16
	for i := 0; i < 256; i++ {
		crc := uint16(i) << 8
		for bit := 0; bit < 8; bit++ {
			if crc&0x8000 != 0 {
				crc = (crc << 1) ^ 0x8005
			} else {
				crc <<= 1
			}
		}
		table[i] = crc
	}
	return table
}

func crc16(data []byte) uint16 {
	var crc uint16
	for _, b := range data {
		crc = (crc << 8) ^ crc16Table[byte(crc>>8)^b]
	}
	return crc
}

// applyStereoDecorrelation undoes the frame's channel assignment in place
// across chBufs[0][:n] and chBufs[1][:n]. It is a no-op for
// ChannelIndependent (every configuration, including mono and multichannel,
// stores its channels directly).
func applyStereoDecorrelation(assignment ChannelAssignment, chBufs [][]int32, n int) error {
	switch assignment {
	case ChannelIndependent:
		return nil
	case ChannelLeftSide:
		if len(chBufs) < 2 {
			return fmt.Errorf("flac: left/side channel assignment requires 2 channels, got %d", len(chBufs))
		}
		left, side := chBufs[0], chBufs[1]
		for i := 0; i < n; i++ {
			side[i] = left[i] - side[i]
		}
		return nil
	case ChannelRightSide:
		if len(chBufs) < 2 {
			return fmt.Errorf("flac: right/side channel assignment requires 2 channels, got %d", len(chBufs))
		}
		side, right := chBufs[0], chBufs[1]
		for i := 0; i < n; i++ {
			side[i] = right[i] + side[i]
		}
		return nil
	case ChannelMidSide:
		if len(chBufs) < 2 {
			return fmt.Errorf("flac: mid/side channel assignment requires 2 channels, got %d", len(chBufs))
		}
		mid, side := chBufs[0], chBufs[1]
		for i := 0; i < n; i++ {
			m := (mid[i] << 1) | (side[i] & 1)
			s := side[i]
			mid[i] = (m + s) >> 1
			side[i] = (m - s) >> 1
		}
		return nil
	default:
		return fmt.Errorf("flac: unrecognised channel assignment %d", assignment)
	}
}

// subframeBitsForChannel returns the bit depth a given channel's subframe
// is coded at: one bit wider than the frame's nominal bits-per-sample for
// whichever channel carries the "side" signal.
func subframeBitsForChannel(header *FrameHeader, channel int) int {
	switch header.ChannelAssignmentType {
	case ChannelLeftSide:
		if channel == 1 {
			return header.BitsPerSample + 1
		}
	case ChannelRightSide:
		if channel == 0 {
			return header.BitsPerSample + 1
		}
	case ChannelMidSide:
		if channel == 1 {
			return header.BitsPerSample + 1
		}
	}
	return header.BitsPerSample
}

// decodeFrame decodes one complete frame from br: the header, every
// channel's subframe, stereo decorrelation, and the trailing CRC-16. It
// writes decoded, decorrelated samples into chBufs, one slice per output
// channel; each slice must have length (or at least capacity accessible via
// re-slicing) of at least info.MaxBlockSize samples, sized by the caller.
func decodeFrame(br *BitReader, info StreamInfo, chBufs [][]int32) (*FrameHeader, error) {
	br.StartCapture()

	header, err := ParseFrameHeader(br, info)
	if err != nil {
		return nil, err
	}

	if header.Channels != len(chBufs) {
		return nil, fmt.Errorf("flac: frame declares %d channels, decoder configured for %d", header.Channels, len(chBufs))
	}
	if info.MaxBlockSize > 0 && header.BlockSize > info.MaxBlockSize {
		return nil, fmt.Errorf("flac: frame block size %d exceeds STREAMINFO maximum %d", header.BlockSize, info.MaxBlockSize)
	}
	for i, buf := range chBufs {
		if header.BlockSize > cap(buf) {
			return nil, fmt.Errorf("flac: frame block size %d exceeds decode buffer capacity %d for channel %d", header.BlockSize, cap(buf), i)
		}
	}

	for ch := 0; ch < header.Channels; ch++ {
		bits := subframeBitsForChannel(header, ch)
		if err := decodeSubframe(br, bits, header.BlockSize, chBufs[ch][:header.BlockSize]); err != nil {
			return nil, fmt.Errorf("flac: channel %d subframe: %w", ch, err)
		}
	}

	if err := applyStereoDecorrelation(header.ChannelAssignmentType, chBufs, header.BlockSize); err != nil {
		return nil, err
	}

	br.Align()
	raw := br.StopCapture()
	computed := crc16(raw)

	crcBytes, err := br.ReadRawBytes(2)
	if err != nil {
		return nil, err
	}
	want := uint16(crcBytes[0])<<8 | uint16(crcBytes[1])
	if computed != want {
		return nil, fmt.Errorf("flac: frame CRC-16 mismatch (computed %#04x, footer says %#04x)", computed, want)
	}

	return header, nil
}
