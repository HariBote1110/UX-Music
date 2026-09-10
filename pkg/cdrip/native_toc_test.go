package cdrip

import (
	"encoding/binary"
	"errors"
	"reflect"
	"testing"
)

func TestParseCDTOC(t *testing.T) {
	tests := []struct {
		name string
		data []tocFixtureEntry
		want TOC
	}{
		{
			name: "normal audio CD",
			data: []tocFixtureEntry{{1, 1, 1, 0, 0, 2, 0}, {1, 2, 1, 0, 0, 5, 0}, {1, 0xa2, 1, 0, 0, 7, 0}},
			want: TOC{Tracks: []TOCTrack{{1, 0, 225, true}, {2, 225, 150, true}}, LeadOutLBA: 375},
		},
		{
			name: "pregap on track one",
			data: []tocFixtureEntry{{1, 1, 1, 0, 0, 0, 0}, {1, 2, 1, 0, 0, 3, 0}, {1, 0xa2, 1, 0, 0, 4, 0}},
			want: TOC{Tracks: []TOCTrack{{1, -150, 225, true}, {2, 75, 75, true}}, LeadOutLBA: 150},
		},
		{
			name: "enhanced CD data session",
			data: []tocFixtureEntry{{1, 1, 1, 0, 0, 2, 0}, {1, 2, 1, 0, 0, 10, 0}, {2, 0xa0, 1, 0, 0, 0, 0}, {2, 3, 1, 0x04, 3, 0, 0}, {2, 0xa2, 1, 0, 4, 0, 0}},
			want: TOC{Tracks: []TOCTrack{{1, 0, 600, true}, {2, 600, 1350, true}, {3, 13350, 4500, false}}, LeadOutLBA: 17850},
		},
		{
			name: "single track",
			data: []tocFixtureEntry{{1, 1, 1, 0, 0, 2, 0}, {1, 0xa2, 1, 0, 10, 0, 0}},
			want: TOC{Tracks: []TOCTrack{{1, 0, 44850, true}}, LeadOutLBA: 44850},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseCDTOC(makeTOCFixture(tt.data))
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("TOC = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestMSFToLBA(t *testing.T) {
	for _, tt := range []struct {
		msf  [3]byte
		want int
	}{{[3]byte{0, 2, 0}, 0}, {[3]byte{4, 16, 13}, 19063}, {[3]byte{80, 0, 0}, 359850}} {
		if got := msfToLBA(tt.msf); got != tt.want {
			t.Errorf("msfToLBA(%v) = %d, want %d", tt.msf, got, tt.want)
		}
	}
}

func TestParseCDTOCMalformed(t *testing.T) {
	for _, fixture := range [][]byte{{}, {0, 2, 1}, {0, 2, 1, 1}, {0, 15, 1, 1, 0}} {
		if _, err := parseCDTOC(fixture); err == nil {
			t.Errorf("parseCDTOC(%v) succeeded", fixture)
		}
	}
}

func TestNoAudioCDError(t *testing.T) {
	var err error = ErrNoAudioCD{Reason: "no optical media"}
	var target ErrNoAudioCD
	if !errors.As(err, &target) || target.Error() != "no audio CD present: no optical media" {
		t.Fatalf("error = %v", err)
	}
}

func TestParseCDTOCWithOnlyDataTrackReturnsTypedError(t *testing.T) {
	_, err := parseCDTOC(makeTOCFixture([]tocFixtureEntry{{1, 1, 1, 0x04, 0, 2, 0}, {1, 0xa2, 1, 0, 0, 4, 0}}))
	var noAudio ErrNoAudioCD
	if !errors.As(err, &noAudio) {
		t.Fatalf("error = %v, want ErrNoAudioCD", err)
	}
}

type tocFixtureEntry struct {
	session, point, adr, control, minute, second, frame byte
}

func makeTOCFixture(entries []tocFixtureEntry) []byte {
	b := make([]byte, 4+len(entries)*11)
	binary.BigEndian.PutUint16(b, uint16(len(entries)*11+2))
	b[2], b[3] = 1, 1
	for i, entry := range entries {
		o := 4 + i*11
		b[o], b[o+1], b[o+2], b[o+3] = entry.session, entry.adr<<4|entry.control, 0, entry.point
		b[o+4], b[o+5], b[o+6] = 0, 0, 0
		b[o+8], b[o+9], b[o+10] = entry.minute, entry.second, entry.frame
	}
	return b
}
