// This file implements RESIDUAL block decoding: the Rice-coded (and
// escape-coded verbatim) prediction residuals that follow a subframe's
// warm-up samples, for both fixed and LPC predictors.
package flac

import "fmt"

// riceEscapeParam4 and riceEscapeParam5 are the all-ones Rice parameter
// values (per coding method) that mean "this partition is escape-coded: an
// unencoded bit width follows, rather than a normal Rice parameter".
const (
	riceEscapeParam4 = 0xF  // 4-bit method (coding method 0)
	riceEscapeParam5 = 0x1F // 5-bit method (coding method 1)
)

// decodeResidual reads a RESIDUAL block from br and writes the decoded
// residual values into out[predictorOrder:blockSize]. out must already have
// length >= blockSize; the first predictorOrder entries (the warm-up
// samples) are left untouched by this function.
func decodeResidual(br *BitReader, blockSize, predictorOrder int, out []int32) error {
	if blockSize <= 0 {
		return fmt.Errorf("flac: residual block size must be positive, got %d", blockSize)
	}
	if predictorOrder < 0 || predictorOrder > blockSize {
		return fmt.Errorf("flac: residual predictor order %d exceeds block size %d", predictorOrder, blockSize)
	}
	if len(out) < blockSize {
		return fmt.Errorf("flac: residual output buffer too small (%d < %d)", len(out), blockSize)
	}

	method, err := br.ReadBits(2)
	if err != nil {
		return err
	}
	if method > 1 {
		return fmt.Errorf("flac: reserved residual coding method %d", method)
	}

	partitionOrderBits, err := br.ReadBits(4)
	if err != nil {
		return err
	}
	partitionOrder := int(partitionOrderBits)
	partitionCount := 1 << uint(partitionOrder)

	if partitionOrder > 0 {
		if blockSize%partitionCount != 0 {
			return fmt.Errorf("flac: residual partition order %d does not evenly divide block size %d", partitionOrder, blockSize)
		}
	}
	samplesPerPartition := blockSize / partitionCount
	if samplesPerPartition == 0 {
		return fmt.Errorf("flac: residual partition order %d produces zero-length partitions for block size %d", partitionOrder, blockSize)
	}
	if samplesPerPartition <= predictorOrder {
		return fmt.Errorf("flac: residual first partition (size %d) is too small for predictor order %d", samplesPerPartition, predictorOrder)
	}

	paramBits := uint(4)
	escapeParam := uint64(riceEscapeParam4)
	if method == 1 {
		paramBits = 5
		escapeParam = riceEscapeParam5
	}

	pos := predictorOrder
	for p := 0; p < partitionCount; p++ {
		count := samplesPerPartition
		if p == 0 {
			count = samplesPerPartition - predictorOrder
		}
		if pos+count > blockSize {
			return fmt.Errorf("flac: residual partitioning overruns block size")
		}

		param, err := br.ReadBits(paramBits)
		if err != nil {
			return err
		}

		if param == escapeParam {
			widthBits, err := br.ReadBits(5)
			if err != nil {
				return err
			}
			width := uint(widthBits)
			if width == 0 {
				for i := 0; i < count; i++ {
					out[pos+i] = 0
				}
			} else {
				for i := 0; i < count; i++ {
					v, err := br.ReadBitsSigned(width)
					if err != nil {
						return err
					}
					out[pos+i] = int32(v)
				}
			}
		} else {
			for i := 0; i < count; i++ {
				v, err := readRiceValue(br, uint(param))
				if err != nil {
					return err
				}
				out[pos+i] = v
			}
		}

		pos += count
	}

	if pos != blockSize {
		return fmt.Errorf("flac: residual decode consumed %d samples, want %d", pos, blockSize)
	}

	return nil
}

// readRiceValue reads a single Rice-coded residual value with parameter k:
// a unary-coded quotient, a k-bit binary remainder, folded (zigzag) back to
// a signed value.
func readRiceValue(br *BitReader, k uint) (int32, error) {
	quotient, err := br.ReadUnary()
	if err != nil {
		return 0, err
	}
	var remainder uint64
	if k > 0 {
		remainder, err = br.ReadBits(k)
		if err != nil {
			return 0, err
		}
	}
	folded := (uint64(quotient) << k) | remainder
	// Zigzag decode: even -> positive half, odd -> negative half.
	signed := int64(folded>>1) ^ -int64(folded&1)
	return int32(signed), nil
}
