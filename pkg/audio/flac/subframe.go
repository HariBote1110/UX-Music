// This file implements FLAC subframe decoding: the per-channel prediction
// methods (constant, verbatim, fixed, LPC) that sit between a frame header
// and its residual-coded samples.
package flac

import "fmt"

// fixedCoefficients holds the standard FLAC fixed-predictor coefficient
// sets, indexed by predictor order (0..4), per RFC 9639 §9.2.2. Coefficient
// i multiplies the sample i+1 positions before the one being predicted.
var fixedCoefficients = [5][]int64{
	0: {},
	1: {1},
	2: {2, -1},
	3: {3, -3, 1},
	4: {4, -6, 4, -1},
}

// decodeSubframe reads one subframe (header, prediction method, and
// residual) from br and writes blockSize decoded, wasted-bits-applied
// samples into out. out must have length >= blockSize; bitsPerSample is the
// nominal bit depth for this channel (already adjusted by the caller for
// the +1 side-channel widening where applicable).
func decodeSubframe(br *BitReader, bitsPerSample, blockSize int, out []int32) error {
	if blockSize <= 0 {
		return fmt.Errorf("flac: subframe block size must be positive, got %d", blockSize)
	}
	if len(out) < blockSize {
		return fmt.Errorf("flac: subframe output buffer too small (%d < %d)", len(out), blockSize)
	}
	if bitsPerSample <= 0 || bitsPerSample > 33 {
		return fmt.Errorf("flac: subframe bits-per-sample %d out of range", bitsPerSample)
	}

	padding, err := br.ReadBits(1)
	if err != nil {
		return err
	}
	if padding != 0 {
		return fmt.Errorf("flac: subframe header padding bit is set (expected 0)")
	}

	typeCode, err := br.ReadBits(6)
	if err != nil {
		return err
	}

	wastedFlag, err := br.ReadBits(1)
	if err != nil {
		return err
	}
	wasted := 0
	if wastedFlag != 0 {
		k, err := br.ReadUnary()
		if err != nil {
			return err
		}
		wasted = int(k) + 1
	}

	effectiveBits := bitsPerSample - wasted
	if effectiveBits <= 0 {
		return fmt.Errorf("flac: subframe wasted bits (%d) leave no sample bits (bits-per-sample %d)", wasted, bitsPerSample)
	}

	switch {
	case typeCode == 0x00:
		if err := decodeConstantSubframe(br, effectiveBits, blockSize, out); err != nil {
			return err
		}
	case typeCode == 0x01:
		if err := decodeVerbatimSubframe(br, effectiveBits, blockSize, out); err != nil {
			return err
		}
	case typeCode >= 0x08 && typeCode <= 0x0C:
		order := int(typeCode - 0x08)
		if err := decodeFixedSubframe(br, effectiveBits, blockSize, order, out); err != nil {
			return err
		}
	case typeCode >= 0x20 && typeCode <= 0x3F:
		order := int(typeCode-0x20) + 1
		if err := decodeLPCSubframe(br, effectiveBits, blockSize, order, out); err != nil {
			return err
		}
	default:
		return fmt.Errorf("flac: reserved subframe type code %#02x", typeCode)
	}

	if wasted > 0 {
		for i := 0; i < blockSize; i++ {
			out[i] <<= uint(wasted)
		}
	}

	return nil
}

func decodeConstantSubframe(br *BitReader, bits, blockSize int, out []int32) error {
	v, err := br.ReadBitsSigned(uint(bits))
	if err != nil {
		return err
	}
	sample := int32(v)
	for i := 0; i < blockSize; i++ {
		out[i] = sample
	}
	return nil
}

func decodeVerbatimSubframe(br *BitReader, bits, blockSize int, out []int32) error {
	for i := 0; i < blockSize; i++ {
		v, err := br.ReadBitsSigned(uint(bits))
		if err != nil {
			return err
		}
		out[i] = int32(v)
	}
	return nil
}

func decodeFixedSubframe(br *BitReader, bits, blockSize, order int, out []int32) error {
	if order < 0 || order > 4 {
		return fmt.Errorf("flac: invalid fixed predictor order %d", order)
	}
	if order > blockSize {
		return fmt.Errorf("flac: fixed predictor order %d exceeds block size %d", order, blockSize)
	}

	for i := 0; i < order; i++ {
		v, err := br.ReadBitsSigned(uint(bits))
		if err != nil {
			return err
		}
		out[i] = int32(v)
	}

	if err := decodeResidual(br, blockSize, order, out); err != nil {
		return err
	}

	coeffs := fixedCoefficients[order]
	for pos := order; pos < blockSize; pos++ {
		var prediction int64
		for i, c := range coeffs {
			prediction += c * int64(out[pos-1-i])
		}
		out[pos] = int32(prediction + int64(out[pos]))
	}

	return nil
}

func decodeLPCSubframe(br *BitReader, bits, blockSize, order int, out []int32) error {
	if order < 1 || order > 32 {
		return fmt.Errorf("flac: invalid LPC predictor order %d", order)
	}
	if order > blockSize {
		return fmt.Errorf("flac: LPC predictor order %d exceeds block size %d", order, blockSize)
	}

	for i := 0; i < order; i++ {
		v, err := br.ReadBitsSigned(uint(bits))
		if err != nil {
			return err
		}
		out[i] = int32(v)
	}

	precisionCode, err := br.ReadBits(4)
	if err != nil {
		return err
	}
	if precisionCode == 0xF {
		return fmt.Errorf("flac: reserved LPC QLP precision code 0xF")
	}
	precision := uint(precisionCode) + 1

	shiftRaw, err := br.ReadBitsSigned(5)
	if err != nil {
		return err
	}
	if shiftRaw < 0 {
		return fmt.Errorf("flac: negative LPC quantisation shift (%d) is invalid", shiftRaw)
	}
	shift := uint(shiftRaw)

	coeffs := make([]int64, order)
	for i := 0; i < order; i++ {
		c, err := br.ReadBitsSigned(precision)
		if err != nil {
			return err
		}
		coeffs[i] = c
	}

	if err := decodeResidual(br, blockSize, order, out); err != nil {
		return err
	}

	for pos := order; pos < blockSize; pos++ {
		var prediction int64
		for i, c := range coeffs {
			prediction += c * int64(out[pos-1-i])
		}
		prediction >>= shift
		out[pos] = int32(prediction + int64(out[pos]))
	}

	return nil
}
