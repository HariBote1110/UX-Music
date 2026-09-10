package cdrip

import (
	"bytes"
	"fmt"
)

type SectorRange struct {
	Start int
	End   int
}

type ReadReport struct {
	Suspicious    []SectorRange
	Unrecoverable []SectorRange
}

type SecureReadOptions struct {
	Mode          string
	MaxAttempts   int
	OffsetSamples int
	Progress      func(sectorsRead int)
}

// SecureReadTrack reads one audio track and returns raw PCM CD-DA bytes.
// OffsetSamples shifts the source position; bytes outside the disc are zero-filled.
func SecureReadTrack(reader DiscReader, trackNumber int, options SecureReadOptions) ([]byte, ReadReport, error) {
	toc, err := reader.ReadTOC()
	if err != nil {
		return nil, ReadReport{}, err
	}
	var track *TOCTrack
	for i := range toc.Tracks {
		if toc.Tracks[i].Number == trackNumber {
			track = &toc.Tracks[i]
			break
		}
	}
	if track == nil || !track.Audio {
		return nil, ReadReport{}, fmt.Errorf("audio track %d not found", trackNumber)
	}
	if options.MaxAttempts < 2 {
		options.MaxAttempts = 3
	}
	result := make([]byte, track.Length*CDSectorBytes)
	report := ReadReport{}
	cache := make(map[int][]byte)
	for relative := 0; relative < track.Length; relative++ {
		destination := result[relative*CDSectorBytes : (relative+1)*CDSectorBytes]
		sourceByte := (track.StartLBA * CDSectorBytes) + relative*CDSectorBytes + options.OffsetSamples*4
		for i := 0; i < CDSectorBytes; i += 4 {
			position := sourceByte + i
			if position < 0 || position >= toc.LeadOutLBA*CDSectorBytes {
				continue
			}
			lba := position / CDSectorBytes
			sector, ok := cache[lba]
			if !ok {
				sector = make([]byte, CDSectorBytes)
				readSector(reader, lba, sector, options, &report, lba-track.StartLBA)
				cache[lba] = sector
			}
			copy(destination[i:], sector[position%CDSectorBytes:position%CDSectorBytes+4])
		}
		if options.Progress != nil {
			options.Progress(relative + 1)
		}
	}
	if len(report.Unrecoverable) > 0 {
		return result, report, fmt.Errorf("unrecoverable sectors: %s", formatRanges(report.Unrecoverable))
	}
	return result, report, nil
}

func readSector(reader DiscReader, lba int, destination []byte, options SecureReadOptions, report *ReadReport, relative int) {
	if options.Mode == "burst" {
		data, err := reader.ReadSectors(lba, 1)
		if err == nil && len(data) >= CDSectorBytes {
			copy(destination, data[:CDSectorBytes])
			return
		}
		appendRange(&report.Unrecoverable, relative)
		return
	}
	reads := make([][]byte, 0, options.MaxAttempts)
	counts := make(map[string]int)
	for attempt := 0; attempt < options.MaxAttempts; attempt++ {
		data, err := reader.ReadSectors(lba, 1)
		if err == nil && len(data) >= CDSectorBytes {
			copyData := append([]byte(nil), data[:CDSectorBytes]...)
			reads = append(reads, copyData)
			counts[string(copyData)]++
			if attempt > 0 && bytes.Equal(reads[len(reads)-1], reads[len(reads)-2]) {
				copy(destination, copyData)
				if attempt > 1 {
					appendRange(&report.Suspicious, relative)
				}
				return
			}
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
