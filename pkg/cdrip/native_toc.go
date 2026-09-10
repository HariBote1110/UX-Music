package cdrip

import (
	"encoding/binary"
	"fmt"
	"sort"
)

const cdTOCDescriptorBytes = 11

// ErrNoAudioCD identifies the expected, user-actionable empty-drive case.
type ErrNoAudioCD struct{ Reason string }

func (e ErrNoAudioCD) Error() string {
	if e.Reason == "" {
		return "no audio CD present"
	}
	return "no audio CD present: " + e.Reason
}

type tocTrackEntry struct {
	number, session, control, start int
}

// msfToLBA converts the binary MSF values used by Apple's CDTOC to the
// CD-relative LBA convention used by DiscReader.
func msfToLBA(msf [3]byte) int {
	return (int(msf[0])*60+int(msf[1]))*75 + int(msf[2]) - 150
}

// parseCDTOC parses CDTOC bytes without importing any Darwin types. CDTOC's
// two-byte length is big-endian and includes the two session-number bytes.
func parseCDTOC(data []byte) (TOC, error) {
	if len(data) < 4 {
		return TOC{}, fmt.Errorf("CDTOC is too short: %d bytes", len(data))
	}
	length := int(binary.BigEndian.Uint16(data[:2]))
	if length < 2 || length%cdTOCDescriptorBytes != 2 {
		return TOC{}, fmt.Errorf("invalid CDTOC length %d", length)
	}
	total := length + 2
	if total > len(data) {
		return TOC{}, fmt.Errorf("short CDTOC: header requires %d bytes, got %d", total, len(data))
	}
	count := (length - 2) / cdTOCDescriptorBytes
	entries := make([]tocTrackEntry, 0, count)
	leadOut := -1
	for i := 0; i < count; i++ {
		d := data[4+i*cdTOCDescriptorBytes : 4+(i+1)*cdTOCDescriptorBytes]
		if d[1]>>4 != 1 {
			continue
		}
		start := msfToLBA([3]byte{d[8], d[9], d[10]})
		switch {
		case d[3] >= 1 && d[3] <= 99:
			entries = append(entries, tocTrackEntry{number: int(d[3]), session: int(d[0]), control: int(d[1] & 0x0f), start: start})
		case d[3] == 0xa2:
			leadOut = start
		}
	}
	if len(entries) == 0 || leadOut < 0 {
		return TOC{}, fmt.Errorf("CDTOC has no complete audio-disc track set")
	}
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].number < entries[j].number })
	tracks := make([]TOCTrack, len(entries))
	for i, entry := range entries {
		end := leadOut
		if i+1 < len(entries) {
			end = entries[i+1].start
		}
		// On an Enhanced CD, the final audio track belongs to the previous
		// session. The session lead-in consumes the conventional 11400 sectors.
		if i+1 < len(entries) && entries[i+1].session > entry.session && entry.control&0x04 == 0 {
			end = entries[i+1].start - 11400
		}
		if end < entry.start {
			return TOC{}, fmt.Errorf("invalid CDTOC track boundary for track %d", entry.number)
		}
		tracks[i] = TOCTrack{Number: entry.number, StartLBA: entry.start, Length: end - entry.start, Audio: entry.control&0x04 == 0}
	}
	for _, track := range tracks {
		if track.Audio {
			return TOC{Tracks: tracks, LeadOutLBA: leadOut}, nil
		}
	}
	return TOC{}, ErrNoAudioCD{Reason: "TOC contains no audio tracks"}
}
