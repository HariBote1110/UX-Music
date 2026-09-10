package cdrip

import (
	"bytes"
	"fmt"
	"io"
)

type SectorRange struct{ Start, End int }
type ReadReport struct{ Suspicious, Unrecoverable []SectorRange }

type SecureReadOptions struct {
	Mode          string
	MaxAttempts   int
	OffsetSamples int
	BlockSize     int
	Progress      func(sectorsRead int)
}

const defaultReadBlockSize = 27

// SecureReadTrack reads one audio track and returns raw PCM CD-DA bytes.
// OffsetSamples shifts the source position; bytes outside the disc are zero-filled.
func SecureReadTrack(reader DiscReader, trackNumber int, options SecureReadOptions) ([]byte, ReadReport, error) {
	var result bytes.Buffer
	report, err := SecureReadTrackTo(&result, reader, trackNumber, options)
	return result.Bytes(), report, err
}

// SecureReadTrackTo streams one audio track as raw PCM CD-DA bytes.
func SecureReadTrackTo(writer io.Writer, reader DiscReader, trackNumber int, options SecureReadOptions) (ReadReport, error) {
	toc, track, err := findAudioTrack(reader, trackNumber)
	if err != nil {
		return ReadReport{}, err
	}
	if options.MaxAttempts < 2 {
		options.MaxAttempts = 3
	}
	if options.BlockSize <= 0 {
		options.BlockSize = defaultReadBlockSize
	}
	report := ReadReport{}
	for outputStart := 0; outputStart < track.Length; outputStart += options.BlockSize {
		outputCount := options.BlockSize
		if remaining := track.Length - outputStart; remaining < outputCount {
			outputCount = remaining
		}
		pcm := make([]byte, outputCount*CDSectorBytes)
		cache := make(map[int][]byte)
		outputByteStart := track.StartLBA*CDSectorBytes + outputStart*CDSectorBytes + options.OffsetSamples*4
		outputByteEnd := outputByteStart + outputCount*CDSectorBytes
		firstLBA := outputByteStart / CDSectorBytes
		if outputByteStart < 0 && outputByteStart%CDSectorBytes != 0 {
			firstLBA--
		}
		if firstLBA < 0 {
			firstLBA = 0
		}
		lastLBA := (outputByteEnd + CDSectorBytes - 1) / CDSectorBytes
		for lba := firstLBA; lba < lastLBA; {
			if lba >= 0 && lba < toc.LeadOutLBA {
				count := options.BlockSize
				if available := toc.LeadOutLBA - lba; available < count {
					count = available
				}
				if needed := lastLBA - lba; needed < count {
					count = needed
				}
				data := readBlock(reader, lba, count, options, &report, lba-track.StartLBA)
				for i := 0; i < count; i++ {
					cache[lba+i] = data[i*CDSectorBytes : (i+1)*CDSectorBytes]
				}
			}
			lba += options.BlockSize
		}
		for relative := 0; relative < outputCount; relative++ {
			destination := pcm[relative*CDSectorBytes : (relative+1)*CDSectorBytes]
			sourceByte := outputByteStart + relative*CDSectorBytes
			for i := 0; i < CDSectorBytes; i += 4 {
				position := sourceByte + i
				if position < 0 || position >= toc.LeadOutLBA*CDSectorBytes {
					continue
				}
				if sector, ok := cache[position/CDSectorBytes]; ok {
					copy(destination[i:], sector[position%CDSectorBytes:position%CDSectorBytes+4])
				}
			}
			if options.Progress != nil {
				options.Progress(outputStart + relative + 1)
			}
		}
		if _, err := writer.Write(pcm); err != nil {
			return report, err
		}
	}
	if len(report.Unrecoverable) > 0 {
		return report, fmt.Errorf("unrecoverable sectors: %s", formatRanges(report.Unrecoverable))
	}
	return report, nil
}

func findAudioTrack(reader DiscReader, trackNumber int) (TOC, *TOCTrack, error) {
	toc, err := reader.ReadTOC()
	if err != nil {
		return TOC{}, nil, err
	}
	for i := range toc.Tracks {
		if toc.Tracks[i].Number == trackNumber && toc.Tracks[i].Audio {
			return toc, &toc.Tracks[i], nil
		}
	}
	return TOC{}, nil, fmt.Errorf("audio track %d not found", trackNumber)
}

func readBlock(reader DiscReader, lba, count int, options SecureReadOptions, report *ReadReport, relative int) []byte {
	result := make([]byte, count*CDSectorBytes)
	first, firstErr := reader.ReadSectors(lba, count)
	if options.Mode == "burst" {
		if firstErr == nil && len(first) >= len(result) {
			copy(result, first[:len(result)])
		} else {
			for i := 0; i < count; i++ {
				appendRange(&report.Unrecoverable, relative+i)
			}
		}
		return result
	}
	second, _ := reader.ReadSectors(lba, count)
	for i := 0; i < count; i++ {
		firstSector, firstOK := blockSector(first, i)
		secondSector, secondOK := blockSector(second, i)
		if firstOK && secondOK && bytes.Equal(firstSector, secondSector) {
			copy(result[i*CDSectorBytes:], firstSector)
			continue
		}
		readSectorCandidates(reader, lba+i, firstSector, firstOK, secondSector, secondOK, options, result[i*CDSectorBytes:], report, relative+i)
	}
	return result
}

func readSectorCandidates(reader DiscReader, lba int, first []byte, firstOK bool, second []byte, secondOK bool, options SecureReadOptions, destination []byte, report *ReadReport, relative int) {
	reads := make([][]byte, 0, options.MaxAttempts)
	counts := make(map[string]int)
	add := func(data []byte, ok bool) {
		if ok {
			copyData := append([]byte(nil), data...)
			reads = append(reads, copyData)
			counts[string(copyData)]++
		}
	}
	add(first, firstOK)
	add(second, secondOK)
	for attempt := 2; attempt < options.MaxAttempts; attempt++ {
		data, err := reader.ReadSectors(lba, 1)
		add(data, err == nil && len(data) >= CDSectorBytes)
		if len(reads) >= 2 && bytes.Equal(reads[len(reads)-1], reads[len(reads)-2]) {
			copy(destination, reads[len(reads)-1])
			appendRange(&report.Suspicious, relative)
			return
		}
	}
	best, bestCount := []byte(nil), 0
	for key, count := range counts {
		if count > bestCount {
			best, bestCount = []byte(key), count
		}
	}
	if bestCount >= 2 && bestCount*2 > len(reads) {
		copy(destination, best)
		appendRange(&report.Suspicious, relative)
		return
	}
	appendRange(&report.Unrecoverable, relative)
}

func blockSector(data []byte, index int) ([]byte, bool) {
	start := index * CDSectorBytes
	if start < 0 || start+CDSectorBytes > len(data) {
		return nil, false
	}
	return data[start : start+CDSectorBytes], true
}

func appendRange(ranges *[]SectorRange, sector int) {
	if n := len(*ranges); n > 0 && (*ranges)[n-1].End+1 == sector {
		(*ranges)[n-1].End = sector
		return
	}
	*ranges = append(*ranges, SectorRange{Start: sector, End: sector})
}

func formatRanges(ranges []SectorRange) string {
	result := ""
	for i, item := range ranges {
		if i > 0 {
			result += ","
		}
		result += fmt.Sprintf("%d-%d", item.Start, item.End)
	}
	return result
}
